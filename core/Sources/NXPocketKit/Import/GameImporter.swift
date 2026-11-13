import Foundation

public struct ImportOptions: Sendable {
    public var verify: VerifyOptions
    /// An unfinished transfer idle for longer than this was cut short (`GameImporter.cleanStaleIncoming`).
    public var incomingIdleLimit: TimeInterval
    /// Free space kept aside beyond what the import writes (`GameImporter.spaceNeeded`), for the system and the game.
    public var headroom: Int64

    public init(verify: VerifyOptions = .default,
                incomingIdleLimit: TimeInterval = GameLayout.incomingIdleLimit,
                headroom: Int64 = 1 << 30) {
        self.verify = verify
        self.incomingIdleLimit = incomingIdleLimit
        self.headroom = headroom
    }

    public static let `default` = ImportOptions()
}

public enum ImportStage: String, Sendable {
    case verifying, signing, installing, indexing, done
}

public struct ImportProgress: Sendable {
    public var stage: ImportStage
    public var fraction: Double
    public var detail: String
}

/// `.incoming/<uuid>` in, `games/<title ID>` out. Nothing is written into the library before the package has been
/// verified and signed, and the hand-off is a `rename`, so a game folder is never half written.
public final class GameImporter {
    public let documents: URL
    public let gamesRoot: URL
    public let incomingRoot: URL
    private let log: ImportLog?
    private let fileManager: FileManager

    public convenience init(documents: URL, fileManager: FileManager = .default) {
        self.init(documents: documents, fileManager: fileManager, log: ImportLog.standard(in: documents))
    }

    public init(documents: URL, fileManager: FileManager = .default, log: ImportLog?) {
        self.documents = documents
        self.fileManager = fileManager
        self.gamesRoot = GameLayout.gamesDirectory(in: documents)
        self.incomingRoot = GameLayout.incomingDirectory(in: documents)
        self.log = log
    }

    public func prepareDirectories() throws {
        for url in [gamesRoot, incomingRoot] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// A fresh `.incoming/<uuid>`, the folder a transfer writes into.
    public func newIncoming() throws -> URL {
        try prepareDirectories()
        let url = incomingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The folder a transfer marked complete, oldest first.
    public func completedIncoming() -> [URL] {
        let names = ((try? fileManager.contentsOfDirectory(atPath: incomingRoot.path)) ?? []).sorted()
        return names.compactMap { name in
            let url = incomingRoot.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: url.appendingPathComponent(GameLayout.completeMarker).path) else { return nil }
            return url
        }
    }

    /// Removes the transfers that will never finish: one its sender marked abandoned, at once, and one in which nothing
    /// has changed for `idleLimit`, whose sender went away (a cable pulled, the Mac app quit). A transfer that carries
    /// `.complete` is kept, however old: it waits for the user to import it.
    @discardableResult
    public func cleanStaleIncoming(now: Date = Date(), idleLimit: TimeInterval = GameLayout.incomingIdleLimit) -> [URL] {
        let names = ((try? fileManager.contentsOfDirectory(atPath: incomingRoot.path)) ?? []).sorted()
        var removed: [URL] = []
        for name in names {
            let url = incomingRoot.appendingPathComponent(name, isDirectory: true)
            guard !fileManager.fileExists(atPath: url.appendingPathComponent(GameLayout.completeMarker).path) else { continue }
            let reason: String
            if fileManager.fileExists(atPath: url.appendingPathComponent(GameLayout.abandonedMarker).path) {
                reason = "the sender could not finish it"
            } else {
                let idle = now.timeIntervalSince(lastActivity(in: url))
                guard idle > idleLimit else { continue }
                reason = "nothing arrived for \(Int(idle / 60)) min"
            }
            guard (try? fileManager.removeItem(at: url)) != nil else { continue }
            removed.append(url)
            log?.append("removed the unfinished transfer \(name): \(reason)")
        }
        return removed
    }

    /// The last time anything in `folder` changed. A file's change time is read along with its modification time:
    /// devicectl gives a copied file the modification time it had on the Mac, so a file that has just arrived can look
    /// hours old by that date alone. The change time cannot be set back, and every write moves it.
    func lastActivity(in folder: URL) -> Date {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .attributeModificationDateKey]
        func latest(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: keys)
            return max(values?.contentModificationDate ?? .distantPast, values?.attributeModificationDate ?? .distantPast)
        }
        var newest = latest(folder)
        if let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in enumerator { newest = max(newest, latest(url)) }
        }
        return newest
    }

    public func verify(_ folder: URL, options: VerifyOptions, progress: (PackageVerifier.Progress) -> Void = { _ in }) throws -> VerifiedPackage {
        do {
            return try PackageVerifier.verify(folder, options: options, fileManager: fileManager, progress: progress)
        } catch let error as NXPocketError {
            log?.append("refused \(folder.lastPathComponent): \(error)")
            throw error
        }
    }

    /// Verifies, signs the framework, then moves the folder into the library. `availableCapacity` is the free space
    /// the volume reports; nil skips the check (a test).
    public func install(_ folder: URL, identity: SigningIdentity?, signer: FrameworkSigner?,
                        options: ImportOptions = .default, availableCapacity: Int64? = nil,
                        progress: @escaping (ImportProgress) -> Void = { _ in }) throws -> InstalledGame {
        progress(ImportProgress(stage: .verifying, fraction: 0, detail: "checking the package"))
        let finderFiles = PackageScanner.removeFinderMetadata(in: folder, fileManager: fileManager)
        if !finderFiles.isEmpty {
            log?.append("removed the Finder's files from \(folder.lastPathComponent): \(finderFiles.joined(separator: ", "))")
        }
        let verified = try verify(folder, options: options.verify) { update in
            progress(ImportProgress(stage: .verifying, fraction: update.fraction * 0.7, detail: update.detail))
        }
        for warning in verified.codeWarnings {
            log?.append("\(verified.package.framework): \(warning)")
        }

        let needed = spaceNeeded(for: verified, headroom: options.headroom)
        if let availableCapacity, availableCapacity < needed {
            throw NXPocketError(.notEnoughSpace,
                                "\(Self.bytes(needed)) needed to sign and install, \(Self.bytes(availableCapacity)) free")
        }

        var record: SigningRecord?
        if signer != nil, let identity, identity.isExpired {
            // Signing with it takes minutes and gives a framework the system refuses to load, with a message that does
            // not say why.
            throw NXPocketError(.certificateExpired, "the certificate expired on \(identity.expires.formatted(date: .abbreviated, time: .omitted))")
        }
        if let signer, let identity {
            progress(ImportProgress(stage: .signing, fraction: 0.75, detail: "signing \(verified.package.framework)"))
            try confirmExecutable(of: verified)
            let signature = try signer.sign(framework: verified.frameworkURL, identity: identity)
            guard signature.hasCertificate else {
                throw NXPocketError(.noCertificate, "the framework came back ad hoc signed: no certificate was used")
            }
            guard signature.identifier == identity.identifier else {
                throw NXPocketError(.wrongSigner,
                                    "the framework was signed as \"\(signature.identifier)\", expected \"\(identity.identifier)\"")
            }
            if let team = signature.teamID, team != identity.teamID {
                throw NXPocketError(.teamMismatch, "the framework was signed for team \(team), expected \(identity.teamID)")
            }
            record = SigningRecord(certificateSHA256: identity.certificateSHA256, identifier: identity.identifier,
                                   teamID: identity.teamID, subject: identity.subject,
                                   signedAt: Date(), expires: identity.expires, entitlements: identity.entitlementsTag)
        } else if identity == nil, signer != nil {
            throw NXPocketError(.noCertificate, "no certificate is installed")
        } else if signer == nil, identity != nil {
            // A certificate and nothing to sign with: the framework would be moved into the library unsigned, listed as
            // a game, and refused by dyld at its first launch.
            throw NXPocketError(.signingFailed, "a certificate is installed but nothing can sign with it: the framework would be installed unsigned")
        }

        progress(ImportProgress(stage: .installing, fraction: 0.85, detail: "installing"))
        let destination = try move(verified, signing: record)
        log?.append("imported \(verified.titleID) \"\(verified.manifest.name)\" from \(folder.lastPathComponent)")
        let game = GameLibrary.entry(at: destination, fileManager: fileManager)
        progress(ImportProgress(stage: .done, fraction: 1, detail: game.title))
        return game
    }

    /// The executable is hashed once more right before it is signed and compared with the listing. The folder lives in
    /// `Documents`, which Files, share extensions and a paired Mac can write to, and the check of the whole package
    /// came some time ago: without this, whatever the executable is by the time zsign opens it gets signed and run
    /// with the app's privileges, with a valid signature that was never compared with the manifest. What remains is
    /// the time zsign itself takes; the signature it writes cannot be compared afterwards, since it changes the hash.
    func confirmExecutable(of verified: VerifiedPackage) throws {
        let relative = verified.manifest.frameworkExecutable
        guard let listed = verified.package.files.first(where: { $0.path == relative }) else {
            throw NXPocketError(.packageInconsistent, "the executable \"\(relative)\" is not listed in the package", path: relative)
        }
        guard try FileDigest.sha256(ofFileAt: verified.executableURL) == listed.sha256 else {
            throw NXPocketError(.hashMismatch, "\"\(relative)\" changed after it was checked and before it was signed", path: relative)
        }
    }

    /// What an import writes beyond the package, which is already on this volume: the move into the library and the
    /// carrying over of a replaced game's saves are renames and cost nothing. Signing writes the executable again into
    /// a fresh file before the old one goes (`tools/zsign_shim.cpp`, rewriteAsFreshFile). Counting the whole package
    /// again, as this once did, asked for twice its size: a 5.5 GB game needed 6.5 GB free beside the 5.5 GB it took.
    func spaceNeeded(for verified: VerifiedPackage, headroom: Int64) -> Int64 {
        let executable = (try? fileManager.attributesOfItem(atPath: verified.executableURL.path)[.size] as? Int64) ?? 0
        return executable + headroom
    }

    /// Replaces a game already in the library, keeping its saves. The library folder is only ever swapped whole.
    private func move(_ verified: VerifiedPackage, signing: SigningRecord?) throws -> URL {
        try prepareDirectories()
        let destination = gamesRoot.appendingPathComponent(verified.titleID.description, isDirectory: true)
        var stale: URL?
        if fileManager.fileExists(atPath: destination.path) {
            let previous = gamesRoot.appendingPathComponent(Self.replacedPrefix + UUID().uuidString, isDirectory: true)
            try fileManager.moveItem(at: destination, to: previous)
            stale = previous
        }
        do {
            try fileManager.moveItem(at: verified.root, to: destination)
        } catch {
            if let stale, !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: stale, to: destination)
            }
            throw NXPocketError(.transferFailed, "the package could not be moved into the library: \(error.localizedDescription)")
        }
        if let signing {
            try? GameLibrary.writeSigning(signing, in: destination, fileManager: fileManager)
        }
        if let stale {
            let left = carrySaves(from: stale, to: destination)
            if left.isEmpty {
                try? fileManager.removeItem(at: stale)
            } else {
                // The replaced folder is the only copy of these saves: it stays, and the next launch tries again
                // (recoverReplacedSaves).
                log?.append("kept \(stale.lastPathComponent): \(left.joined(separator: ", ")) could not be carried into \(destination.lastPathComponent)")
            }
        }
        return destination
    }

    /// Moves the `save*` entries of a replaced folder into the new one: a game's progress is never lost to an update.
    /// A move is a rename on this volume, so it needs no space and cannot leave half a save. Returns the entries
    /// still in `previous`; one the new folder already has stays there too, rather than overwrite either.
    @discardableResult
    func carrySaves(from previous: URL, to destination: URL) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: previous.path)) ?? []
        var left: [String] = []
        for name in names.sorted() where name.hasPrefix("save") {
            let target = destination.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                left.append(name)
                continue
            }
            do { try fileManager.moveItem(at: previous.appendingPathComponent(name), to: target) }
            catch { left.append(name) }
        }
        return left
    }

    /// The replaced folders an earlier import could not empty of their saves, given back to their game. A folder is
    /// deleted only once no save is left in it, and one whose game is gone is left alone.
    @discardableResult
    public func recoverReplacedSaves() -> [String] {
        let names = ((try? fileManager.contentsOfDirectory(atPath: gamesRoot.path)) ?? []).filter { $0.hasPrefix(Self.replacedPrefix) }
        var recovered: [String] = []
        for name in names.sorted() {
            let stale = gamesRoot.appendingPathComponent(name, isDirectory: true)
            guard let package = try? PackageVerifier.loadPackage(stale, fileManager: fileManager),
                  let titleID = TitleID(package.titleID) else { continue }
            let game = gamesRoot.appendingPathComponent(titleID.description, isDirectory: true)
            guard fileManager.fileExists(atPath: game.path) else { continue }
            let left = carrySaves(from: stale, to: game)
            if left.isEmpty {
                try? fileManager.removeItem(at: stale)
                recovered.append(titleID.description)
                log?.append("gave \(titleID) back the saves kept in \(name)")
            }
        }
        return recovered
    }

    static let replacedPrefix = ".replaced-"

    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
