import CryptoKit
import Foundation

public struct DownloadProgress: Equatable, Sendable {
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// The file being fetched, relative to the package.
    public var path: String
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

/// Fetches one game from a `PackageSource` into `Documents/.incoming/<uuid>/`, the folder a push from the Mac also ends
/// up in, and writes `.complete` last. From there the importer does what it always does: verify, sign, `rename`.
///
/// The phone trusts neither the source nor the network, so this is where the rules of `docs/SHARING.md` §6 live:
/// the plan comes from `package.json` (`DownloadPlan`); only planned paths are asked for and written; a body that is
/// longer than its file is refused; a file with a hash is hashed as it arrives and refused when it does not match; the
/// space is checked before anything is written; and `.complete` is the phone's own word that every planned file is on
/// disk whole.
///
/// A task that is cancelled leaves the folder and its journal in place (a pause); `discard` is the cancel.
public struct PackageDownloader: Sendable {
    public let documents: URL
    public var availableSpace: @Sendable () -> Int64?
    public var headroom: Int64
    public var maximumMinimumOS: OSVersion
    public var checkpointBytes: Int64
    /// The `romfs.img` this phone already holds for a game, if any: an update starts from a clone of it and fetches only the
    /// blocks that differ (`RomfsBlocks`). Nil, or a game whose package has no list, downloads the image whole.
    public var reference: @Sendable (TitleID) -> URL?

    public init(documents: URL, availableSpace: @escaping @Sendable () -> Int64? = { nil }, headroom: Int64 = 1 << 30,
                maximumMinimumOS: OSVersion = .current, checkpointBytes: Int64 = SharingLimits.checkpointBytes,
                reference: @escaping @Sendable (TitleID) -> URL? = { _ in nil }) {
        self.reference = reference
        self.documents = documents
        self.availableSpace = availableSpace
        self.headroom = headroom
        self.maximumMinimumOS = maximumMinimumOS
        self.checkpointBytes = checkpointBytes
    }

    /// Downloads `game` and returns its transfer folder, marked `.complete`. Throws `NXPocketError(.cancelled)` when the
    /// task is cancelled, with everything fetched so far kept for the next call to resume.
    ///
    /// `alsoFrom` names other sources that hold the same game (their `sourceID`s): a transfer another of them left unfinished is
    /// taken over when its package is the same build and carries the list of the image's blocks, which checks, at the end, that
    /// the image put together from two sources is the build's. A Mac that goes to sleep in the middle of a download is then
    /// finished from the NAS, from where it stopped.
    public func download(_ game: RemoteGame, from source: PackageSource, alsoFrom others: [String] = [],
                         progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> URL {
        guard let titleID = TitleID(game.titleID), titleID.kind == .application else {
            throw NXPocketError(.packageDamaged, "\"\(game.titleID)\" is not a game's title ID")
        }
        // A rebuild during the download changes what the source holds under the old revision: the plan is dropped and
        // the game starts again, once. A second change is the player's to see ("keeps changing on the Mac").
        for attempt in 0...1 {
            do {
                return try await run(titleID: titleID, source: source, alsoFrom: others, progress: progress)
            } catch PackageSourceError.changed where attempt == 0 {
                Self.discard(sourceID: source.sourceID, titleID: titleID, documents: documents)
                continue
            } catch PackageSourceError.changed {
                Self.discard(sourceID: source.sourceID, titleID: titleID, documents: documents)
                throw NXPocketError(.transferFailed, "the game keeps changing on its source; try again once it is done")
            } catch {
                // A connection cut by the cancellation surfaces as the network's error: the pause is what happened.
                if Task.isCancelled { throw NXPocketError(.cancelled, "paused") }
                throw Self.normalised(error)
            }
        }
        throw NXPocketError(.transferFailed, "the download could not be started")
    }

    /// What a caller sees: an `NXPocketError` for anything that went wrong on the way (so a screen has one thing to
    /// explain), and a `PackageSourceError` only for the ones the player acts on (pair again, trust a key, wait).
    static func normalised(_ error: Error) -> Error {
        switch error {
        case let error as NXPocketError:
            return error
        case PackageSourceError.unreachable(let detail), PackageSourceError.malformed(let detail):
            return NXPocketError(.transferFailed, detail)
        case is PackageSourceError:
            return error
        case is CancellationError:
            return NXPocketError(.cancelled, "paused")
        default:
            return NXPocketError(.transferFailed, error.localizedDescription)
        }
    }

    // MARK: - One attempt

    private func run(titleID: TitleID, source: PackageSource, alsoFrom others: [String],
                     progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let listing = try await source.listing(titleID: titleID.description)
        let manifestData = try await Self.readWhole(source, titleID: titleID, revision: listing.revision,
                                                    path: GamePackage.fileName, limit: SharingLimits.metadataBytes)
        let plan: DownloadPlan
        do {
            plan = try DownloadPlan.make(manifestData: manifestData, listing: listing, expected: titleID,
                                         maximumMinimumOS: maximumMinimumOS)
        } catch let error as NXPocketError {
            if Self.isPackageFault(error.code) { Self.discard(sourceID: source.sourceID, titleID: titleID, documents: documents) }
            throw error
        }

        // An update of a game this phone holds, whose package carries the list of blocks: the image is built from a clone of the
        // one held, and the space it needs is known once it has been compared, not before.
        let held = plan.blocks != nil && plan.package.romfsSize > 0 ? reference(titleID).flatMap { Session.size(of: $0) != nil ? $0 : nil } : nil
        let state = try prepare(plan: plan, sourceID: source.sourceID, alsoFrom: plan.blocks != nil ? others : [], imageFromReference: held != nil)
        let session = Session(downloader: self, plan: plan, source: source, folder: state.folder, journal: state.journal,
                              done: Int64(plan.manifestData.count), report: progress)
        session.reference = held
        do {
            for item in plan.items {
                if Task.isCancelled { throw NXPocketError(.cancelled, "paused") }
                try await session.fetch(item)
            }
            if Task.isCancelled { throw NXPocketError(.cancelled, "paused") }
            // An image put together from the work of two sources is read whole against the list before it is called complete.
            if state.adopted, plan.package.romfsBlocks != nil {
                try await Self.settleAdopted(folder: state.folder, plan: plan, source: source)
            }
            try session.finish()
            return state.folder
        } catch let error as NXPocketError where Self.isPackageFault(error.code) {
            try? FileManager.default.removeItem(at: state.folder)
            throw error
        }
    }

    /// Finds the folder an earlier run left, or makes a new one, after checking there is room. A folder of another build
    /// of the game is removed: its bytes belong to a package that no longer exists.
    private func prepare(plan: DownloadPlan, sourceID: String, alsoFrom others: [String] = [],
                         imageFromReference: Bool = false) throws -> (folder: URL, journal: DownloadJournal, adopted: Bool) {
        let fileManager = FileManager.default
        var journal = DownloadJournal(sourceID: sourceID, titleID: plan.titleID.description, revision: plan.revision)
        var folder: URL?
        var adopted = false
        if let existing = Self.findFolder(sourceIDs: Set([sourceID] + others), titleID: plan.titleID, documents: documents) {
            if existing.journal.revision == plan.revision {
                folder = existing.folder
                journal = existing.journal
                if journal.sourceID != sourceID {
                    // Another source's unfinished transfer of this very build: it goes on from here, under this source's name.
                    journal.sourceID = sourceID
                    try? journal.write(in: existing.folder)
                    adopted = true
                }
            } else {
                try? fileManager.removeItem(at: existing.folder)
            }
        }

        let onDisk = folder.map { Self.bytesKept(in: $0, journal: journal, plan: plan) } ?? 0
        // `package.json` is written again from the plan on a resume: what is in the folder is only the plan's if it is.
        if let folder {
            try? plan.manifestData.write(to: folder.appendingPathComponent(GamePackage.fileName), options: .atomic)
        }
        let largestFramework = plan.items.filter { $0.sha256 != nil }.map(\.size).max() ?? 0
        // Starting from a clone, the image costs only the blocks that differ, which `fetchDifferentially` checks against the free space.
        let imageShare = imageFromReference ? plan.package.romfsSize : 0
        let needed = max(plan.totalBytes - imageShare - (imageFromReference ? 0 : onDisk), 0) + largestFramework + headroom
        if let free = availableSpace(), free < needed {
            throw NXPocketError(.notEnoughSpace, "\(GameImporter.bytes(needed)) needed, \(GameImporter.bytes(free)) free")
        }

        if let folder { return (folder, journal, adopted) }
        let root = GameLayout.incomingDirectory(in: documents)
        let created = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: created, withIntermediateDirectories: true)
        do {
            try plan.manifestData.write(to: created.appendingPathComponent(GamePackage.fileName), options: .atomic)
            try journal.write(in: created)
        } catch {
            try? fileManager.removeItem(at: created)
            throw NXPocketError(.transferFailed, "the transfer folder could not be written: \(error.localizedDescription)")
        }
        return (created, journal, false)
    }

    // MARK: - One file

    /// The state of one transfer while it runs. A class, so the file loop and the journal share it; it lives inside a
    /// single call to `run`, never crossing tasks.
    private final class Session {
        let downloader: PackageDownloader
        let plan: DownloadPlan
        let source: PackageSource
        let folder: URL
        var journal: DownloadJournal
        var done: Int64
        let report: @Sendable (DownloadProgress) -> Void
        var lastReport: UInt64 = 0
        var lastJournal: UInt64 = 0
        /// The image already on this phone, when the update is built from it.
        var reference: URL?

        init(downloader: PackageDownloader, plan: DownloadPlan, source: PackageSource, folder: URL, journal: DownloadJournal,
             done: Int64, report: @escaping @Sendable (DownloadProgress) -> Void) {
            self.downloader = downloader
            self.plan = plan
            self.source = source
            self.folder = folder
            self.journal = journal
            self.done = done
            self.report = report
        }

        func fetch(_ item: DownloadPlan.Item) async throws {
            let url = folder.appendingPathComponent(item.path)
            // Only the files with no hash are in the journal's `completed`: the others are found again by their hash,
            // which keeps the journal small however many files a framework has.
            if item.sha256 == nil, journal.completed.contains(item.path), Self.size(of: url) == item.size {
                done += item.size
                return
            }
            try prepareParent(of: url, item: item)

            if item.path == GameLayout.romfsFile, let reference, let blocks = plan.blocks {
                try await fetchDifferentially(item, from: reference, blocks: blocks)
                return
            }

            // A file with a hash that is already whole on disk costs one hash instead of a download.
            if let expected = item.sha256, Self.size(of: url) == item.size,
               (try? FileDigest.sha256(ofFileAt: url)) == expected {
                done += item.size
                markCompleted(item, force: false)
                reportProgress(item)
                return
            }

            var offset = journal.partialPath == item.path ? min(max(journal.partialOffset, 0), item.size) : 0
            var sink: FileSink
            do { sink = try FileSink(url: url, offset: offset) }
            catch let error as NXPocketError where error.code == .transferFailed && offset > 0 {
                offset = 0                   // the file is shorter than the journal says: that file starts again
                sink = try FileSink(url: url, offset: 0)
            }
            var hasher = SHA256()
            if item.sha256 != nil, offset > 0 {
                try Self.hashPrefix(of: url, length: offset, into: &hasher)
            }
            done += offset
            var written = offset

            if written < item.size {
                let body = try await source.read(titleID: plan.titleID.description, revision: plan.revision,
                                                 path: item.path, offset: UInt64(written))
                guard body.offset == UInt64(written) else {
                    throw NXPocketError(.transferFailed, "the source answered from byte \(body.offset), not from \(written)", path: item.path)
                }
                guard body.length.map({ $0 <= UInt64(item.size - written) }) ?? true else {
                    throw NXPocketError(.sizeMismatch, "the source announces more bytes than \(item.path) has", path: item.path)
                }
                var sinceCheckpoint: Int64 = 0
                do {
                    for try await chunk in body.chunks {
                        if Task.isCancelled { break }
                        guard Int64(chunk.count) <= item.size - written else {
                            throw NXPocketError(.sizeMismatch, "the source sent more bytes than \(item.path) has", path: item.path)
                        }
                        try sink.write(chunk)
                        if item.sha256 != nil { hasher.update(data: chunk) }
                        written += Int64(chunk.count)
                        done += Int64(chunk.count)
                        sinceCheckpoint += Int64(chunk.count)
                        if sinceCheckpoint >= downloader.checkpointBytes {
                            try sink.sync()
                            checkpoint(item, written: written)
                            sinceCheckpoint = 0
                        }
                        reportProgress(item)
                    }
                } catch let error as NXPocketError where Self.isHostile(error.code) {
                    throw error
                } catch {
                    // A dropped connection, a stalled source: what arrived is kept, and the journal says how much.
                    try? sink.sync()
                    checkpoint(item, written: written)
                    throw error
                }
                if written < item.size {
                    try? sink.sync()
                    checkpoint(item, written: written)
                    if Task.isCancelled { throw NXPocketError(.cancelled, "paused") }
                    throw NXPocketError(.transferFailed, "the connection ended after \(written) of \(item.size) bytes of \(item.path)", path: item.path)
                }
            }

            try sink.sync()
            sink.close()
            if let expected = item.sha256, FileDigest.hex(hasher.finalize()) != expected {
                throw NXPocketError(.hashMismatch, "\"\(item.path)\" does not match its sha256", path: item.path)
            }
            markCompleted(item, force: item.sha256 == nil)
            reportProgress(item, force: true)
        }

        // MARK: the image of an update

        /// Builds `romfs.img` from a clone of the image this phone holds. Every block of it is compared with the list (`romfs.blocks`,
        /// already fetched and checked against `package.json`); the ones that match stay, and the others come from the source, in
        /// runs, each checked against the list before it is kept. Nothing here trusts the file's earlier state: a clone cut short, a
        /// resume, an image of another size are all compared the same way, so what ends up on disk is the list's image or a refusal.
        func fetchDifferentially(_ item: DownloadPlan.Item, from reference: URL, blocks declared: RomfsBlocks) async throws {
            let url = folder.appendingPathComponent(item.path)
            let list = try readBlockList(declared)
            let blockSize = Int64(declared.blockSize)
            let count = declared.count(forImageOf: item.size)
            guard list.count == count else {
                throw NXPocketError(.packageDamaged, "the list of blocks has \(list.count) hashes, the image needs \(count)", path: GameLayout.romfsBlocksFile)
            }
            let fileManager = FileManager.default
            if Self.size(of: url) == nil {
                // On APFS a copy is a clone: no byte is copied and no space is used until a block changes.
                do { try fileManager.copyItem(at: reference, to: url) }
                catch { throw NXPocketError(.transferFailed, "the image held could not be copied: \(error.localizedDescription)", path: item.path) }
            }
            let handle: FileHandle
            do { handle = try FileHandle(forUpdating: url) }
            catch { throw NXPocketError(.transferFailed, "\(item.path) could not be opened: \(error.localizedDescription)", path: item.path) }
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(item.size))

            // 1. Which blocks differ. Nothing is written.
            var bad: [Int] = []
            for index in 0..<count {
                if Task.isCancelled { throw NXPocketError(.cancelled, "paused") }
                let length = Int(min(blockSize, item.size - Int64(index) * blockSize))
                try handle.seek(toOffset: UInt64(Int64(index) * blockSize))
                let block = try handle.read(upToCount: length) ?? Data()
                if block.count == length, Data(SHA256.hash(data: block)) == list[index] {
                    done += Int64(length)
                    reportProgress(item)
                } else {
                    bad.append(index)
                }
            }

            // 2. Whether the others fit.
            let badBytes = bad.reduce(Int64(0)) { $0 + min(blockSize, item.size - Int64($1) * blockSize) }
            if let free = downloader.availableSpace(), free < badBytes + downloader.headroom {
                throw NXPocketError(.notEnoughSpace, "\(GameImporter.bytes(badBytes + downloader.headroom)) needed, \(GameImporter.bytes(free)) free")
            }

            // 3. The blocks that differ, a run of neighbours in one request, each block checked as it completes.
            var position = 0
            while position < bad.count {
                if Task.isCancelled { throw NXPocketError(.cancelled, "paused") }
                var last = position
                while last + 1 < bad.count, bad[last + 1] == bad[last] + 1 { last += 1 }
                try await fetchRun(blocks: bad[position]...bad[last], item: item, list: list, blockSize: blockSize, into: handle)
                position = last + 1
            }
            try handle.synchronize()
            markCompleted(item, force: true)
            reportProgress(item, force: true)
        }

        private func fetchRun(blocks: ClosedRange<Int>, item: DownloadPlan.Item, list: [Data], blockSize: Int64, into handle: FileHandle) async throws {
            let start = Int64(blocks.lowerBound) * blockSize
            let end = min(Int64(blocks.upperBound + 1) * blockSize, item.size)
            let body = try await source.read(titleID: plan.titleID.description, revision: plan.revision, path: item.path, offset: UInt64(start))
            guard body.offset == UInt64(start) else {
                throw NXPocketError(.transferFailed, "the source answered from byte \(body.offset), not from \(start)", path: item.path)
            }
            guard body.length.map({ $0 <= UInt64(item.size - start) }) ?? true else {
                throw NXPocketError(.sizeMismatch, "the source announces more bytes than \(item.path) has", path: item.path)
            }
            var pending = Data()
            var next = blocks.lowerBound
            var written = start
            for try await chunk in body.chunks {
                if Task.isCancelled { throw NXPocketError(.cancelled, "paused") }
                pending.append(chunk)
                while next <= blocks.upperBound {
                    let length = Int(min(blockSize, item.size - Int64(next) * blockSize))
                    guard pending.count >= length else { break }
                    let block = pending.prefix(length)
                    guard Data(SHA256.hash(data: block)) == list[next] else {
                        throw NXPocketError(.hashMismatch, "block \(next) of \(item.path) does not match the list", path: item.path)
                    }
                    try handle.seek(toOffset: UInt64(written))
                    try handle.write(contentsOf: block)
                    written += Int64(length)
                    done += Int64(length)
                    pending = Data(pending.dropFirst(length))
                    next += 1
                    reportProgress(item)
                }
                if next > blocks.upperBound { break }
            }
            guard written == end else {
                if Task.isCancelled { throw NXPocketError(.cancelled, "paused") }
                throw NXPocketError(.transferFailed, "the connection ended after \(written - start) of \(end - start) bytes of \(item.path)", path: item.path)
            }
        }

        /// The list of blocks, read from the folder (it was fetched and checked against `package.json` before the image) and cut
        /// into its hashes.
        private func readBlockList(_ declared: RomfsBlocks) throws -> [Data] {
            let url = folder.appendingPathComponent(GameLayout.romfsBlocksFile)
            guard let data = BoundedRead.dataIfPresent(at: url, limit: Int64(RomfsBlocks.maxListBytes)),
                  FileDigest.sha256(of: data) == declared.sha256, data.count % RomfsBlocks.digestBytes == 0 else {
                throw NXPocketError(.packageDamaged, "the list of blocks is not the one \(GamePackage.fileName) names", path: GameLayout.romfsBlocksFile)
            }
            return stride(from: 0, to: data.count, by: RomfsBlocks.digestBytes).map { data.subdata(in: $0..<($0 + RomfsBlocks.digestBytes)) }
        }

        /// Everything is on disk: the folder is complete, in the phone's own word. The journal goes after the marker, and
        /// the importer drops a journal that stays behind.
        func finish() throws {
            let fileManager = FileManager.default
            for item in plan.items where Self.size(of: folder.appendingPathComponent(item.path)) != item.size {
                throw NXPocketError(.transferFailed, "\(item.path) is not whole on disk", path: item.path)
            }
            try Data().write(to: folder.appendingPathComponent(GameLayout.completeMarker), options: .atomic)
            try? fileManager.removeItem(at: DownloadJournal.url(in: folder))
            report(DownloadProgress(bytesDone: plan.totalBytes, bytesTotal: plan.totalBytes, path: ""))
        }

        // MARK: journal

        func checkpoint(_ item: DownloadPlan.Item, written: Int64) {
            journal.partialPath = item.path
            journal.partialOffset = written
            try? journal.write(in: folder)
        }

        func markCompleted(_ item: DownloadPlan.Item, force: Bool) {
            if item.sha256 == nil, !journal.completed.contains(item.path) { journal.completed.append(item.path) }
            // Only this file's own entry goes: another file may be the one the journal is keeping a place in.
            if journal.partialPath == item.path {
                journal.partialPath = nil
                journal.partialOffset = 0
            }
            // Many small files finish within milliseconds; their journal is written every few seconds and what is lost
            // in a crash is one cheap hash per file (above).
            let now = DispatchTime.now().uptimeNanoseconds
            if force || now - lastJournal > 2_000_000_000 {
                try? journal.write(in: folder)
                lastJournal = now
            }
        }

        func reportProgress(_ item: DownloadPlan.Item, force: Bool = false) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard force || now - lastReport > 100_000_000 else { return }
            lastReport = now
            report(DownloadProgress(bytesDone: min(done, plan.totalBytes), bytesTotal: plan.totalBytes, path: item.path))
        }

        // MARK: files

        /// The planned path's folders, made one by one: none may be a link, so no write can leave the transfer folder.
        func prepareParent(of url: URL, item: DownloadPlan.Item) throws {
            let fileManager = FileManager.default
            var current = folder
            for component in item.path.split(separator: "/").dropLast() {
                current.appendPathComponent(String(component), isDirectory: true)
                if PackageScanner.isSymbolicLink(current) {
                    throw NXPocketError(.symbolicLink, "a link stands where a folder of the package goes", path: item.path)
                }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else {
                        throw NXPocketError(.packageInconsistent, "a file stands where a folder of the package goes", path: item.path)
                    }
                } else {
                    try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
                }
            }
        }

        static func size(of url: URL) -> Int64? {
            var info = stat()
            return url.withUnsafeFileSystemRepresentation { path in
                guard let path, lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
                return Int64(info.st_size)
            }
        }

        static func hashPrefix(of url: URL, length: Int64, into hasher: inout SHA256) throws {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw NXPocketError(.transferFailed, "\(url.lastPathComponent) could not be read back", path: url.lastPathComponent)
            }
            defer { try? handle.close() }
            var left = length
            while left > 0 {
                guard let chunk = try? handle.read(upToCount: Int(min(left, Int64(FileDigest.chunkSize)))), !chunk.isEmpty else {
                    throw NXPocketError(.transferFailed, "\(url.lastPathComponent) is shorter than the journal says", path: url.lastPathComponent)
                }
                hasher.update(data: chunk)
                left -= Int64(chunk.count)
            }
        }

        static func isHostile(_ code: NXPocketError.Code) -> Bool { PackageDownloader.isPackageFault(code) || code == .cancelled }
    }

    // MARK: - Folders

    /// The failures that say the package itself is wrong: its folder is deleted, as no retry can fix it. A failed network,
    /// a full disk, a pause or a missing certificate keep what was fetched.
    public static func isPackageFault(_ code: NXPocketError.Code) -> Bool {
        switch code {
        case .hashMismatch, .sizeMismatch, .packageDamaged, .packageInconsistent, .packageUnsupported, .packageMissing,
             .unsafePath, .symbolicLink:
            return true
        default:
            return false
        }
    }

    /// The unfinished transfer of this game from this source, if one is waiting. Any other folder for the same pair (it
    /// should not exist) is removed, so a gigabyte is never kept twice.
    static func findFolder(sourceID: String, titleID: TitleID, documents: URL) -> (folder: URL, journal: DownloadJournal)? {
        findFolder(sourceIDs: [sourceID], titleID: titleID, documents: documents)
    }

    static func findFolder(sourceIDs: Set<String>, titleID: TitleID, documents: URL) -> (folder: URL, journal: DownloadJournal)? {
        let fileManager = FileManager.default
        let root = GameLayout.incomingDirectory(in: documents)
        var found: [(URL, DownloadJournal)] = []
        for name in ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard !fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path),
                  let journal = DownloadJournal.read(in: folder),
                  sourceIDs.contains(journal.sourceID), TitleID(journal.titleID) == titleID else { continue }
            found.append((folder, journal))
        }
        found.sort { $0.1.started < $1.1.started }
        guard let newest = found.last else { return nil }
        for (folder, _) in found.dropLast() { try? fileManager.removeItem(at: folder) }
        return (newest.0, newest.1)
    }

    /// Reads the image of a transfer two sources worked on against the list of its blocks, and puts right what does not match from
    /// the source that finishes it. An image that still does not match is a package fault.
    static func settleAdopted(folder: URL, plan: DownloadPlan, source: PackageSource) async throws {
        let scan = try GameRepair.scan(directory: folder, package: plan.package)
        guard !scan.isClean else { return }
        try await GameRepair.repair(directory: folder, package: plan.package, scan: scan, from: source)
        guard try GameRepair.scan(directory: folder, package: plan.package).isClean else {
            throw NXPocketError(.hashMismatch, "the image put together from two sources does not match its list", path: GameLayout.romfsFile)
        }
    }

    /// The cancel: forgets a game's unfinished download and gives its space back.
    public static func discard(sourceID: String, titleID: TitleID, documents: URL) {
        let fileManager = FileManager.default
        let root = GameLayout.incomingDirectory(in: documents)
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let journal = DownloadJournal.read(in: folder), journal.sourceID == sourceID,
                  TitleID(journal.titleID) == titleID,
                  !fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path) else { continue }
            try? fileManager.removeItem(at: folder)
        }
    }

    /// The downloads waiting in `.incoming`, paused by the player or cut short.
    public static func pending(documents: URL) -> [PendingDownload] {
        let fileManager = FileManager.default
        let root = GameLayout.incomingDirectory(in: documents)
        return ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).sorted().compactMap { name in
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard !fileManager.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path),
                  let journal = DownloadJournal.read(in: folder),
                  let package = try? PackageVerifier.loadPackage(folder) else { return nil }
            let manifestBytes = Session.size(of: folder.appendingPathComponent(GamePackage.fileName)) ?? 0
            return PendingDownload(folder: folder, sourceID: journal.sourceID, titleID: journal.titleID, name: package.name,
                                   revision: journal.revision, bytesDone: bytesOnDisk(in: folder, journal: journal),
                                   bytesTotal: package.totalSize + manifestBytes)
        }
    }

    /// What the plan's files hold on disk now, counted the way a resume will use it: finished files whole, the file in
    /// flight up to its journaled offset.
    static func bytesKept(in folder: URL, journal: DownloadJournal, plan: DownloadPlan) -> Int64 {
        var total = Int64(plan.manifestData.count)
        for item in plan.items {
            let size = Session.size(of: folder.appendingPathComponent(item.path))
            if item.sha256 != nil, let size {
                total += min(size, item.size)
            } else if journal.completed.contains(item.path), size == item.size {
                total += item.size
            } else if journal.partialPath == item.path {
                total += min(max(journal.partialOffset, 0), item.size)
            }
        }
        return total
    }

    static func bytesOnDisk(in folder: URL, journal: DownloadJournal) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, url.lastPathComponent != GameLayout.downloadJournal { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// A small file, whole, refused beyond `limit`.
    static func readWhole(_ source: PackageSource, titleID: TitleID, revision: String, path: String, limit: Int) async throws -> Data {
        let body = try await source.read(titleID: titleID.description, revision: revision, path: path, offset: 0)
        guard body.offset == 0 else { throw NXPocketError(.transferFailed, "the source answered from byte \(body.offset)", path: path) }
        guard body.length.map({ $0 <= UInt64(limit) }) ?? true else {
            throw NXPocketError(.packageDamaged, "\(path) is larger than \(limit) bytes", path: path)
        }
        var data = Data()
        for try await chunk in body.chunks {
            data.append(chunk)
            guard data.count <= limit else { throw NXPocketError(.packageDamaged, "\(path) is larger than \(limit) bytes", path: path) }
        }
        try Task.checkCancellation()
        return data
    }
}
