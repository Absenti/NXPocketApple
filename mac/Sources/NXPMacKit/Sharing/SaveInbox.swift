import Foundation
import NXPocketKit

/// Where the copies of saves a paired iPhone sends end up: `<output folder>/Saves/<title ID>/iPhone <date>.zip`, beside the
/// folders `SaveBackup` makes from a cable. The server writes nothing else anywhere.
///
/// A copy is written into a hidden `.upload-<uuid>` file, checked to start like a .zip and to be exactly as long as the phone
/// said, and only then renamed to its name. The .zip is kept as it arrived and is never opened here: what the phone sent is
/// not trusted to be anything but bytes. The last `SaveUpload.keep` copies of a game are kept; only files named the way this
/// class names them are ever counted or removed.
public final class SaveInbox: @unchecked Sendable {
    public enum Refusal: Error, Equatable {
        /// The player switched "accept saves" off.
        case off
        case notAGame
        case tooLarge
        case noRoom
        case notAZip
        case cut
    }

    private let outputFolder: @Sendable () -> URL
    private let accepting: @Sendable () -> Bool
    private let fileManager: FileManager
    private let room: @Sendable (URL) -> Int64?

    /// `room` is for tests: the bytes free where the copies go.
    public init(outputFolder: @escaping @Sendable () -> URL, accepting: @escaping @Sendable () -> Bool = { true },
                fileManager: FileManager = .default, room: @escaping @Sendable (URL) -> Int64? = { SaveInbox.freeSpace($0) }) {
        self.outputFolder = outputFolder
        self.accepting = accepting
        self.fileManager = fileManager
        self.room = room
    }

    public static func freeSpace(_ folder: URL) -> Int64? {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    public var isAccepting: Bool { accepting() }

    /// Opens a copy of `length` bytes for `titleID`. Everything that can be refused is refused here, before a byte is read.
    func begin(titleID: String, length: Int64) throws -> Upload {
        guard accepting() else { throw Refusal.off }
        guard TitleID.isGame(titleID), let id = TitleID(titleID) else { throw Refusal.notAGame }
        guard length > 0, length <= SaveUpload.maxBytes else { throw Refusal.tooLarge }
        let gameFolder = SaveBackup.folder(of: id.description, in: outputFolder())
        // Twice the copy, and a little more: the folder must keep room for what the Mac itself is doing.
        if let free = room(gameFolder), free < length * 2 + (64 << 20) { throw Refusal.noRoom }
        try fileManager.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        for name in (try? fileManager.contentsOfDirectory(atPath: gameFolder.path)) ?? [] where name.hasPrefix(Upload.prefix) {
            // A copy cut off by a quit is not a copy; one still arriving (another phone) is younger than a minute.
            let url = gameFolder.appendingPathComponent(name)
            let age = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate).map { Date().timeIntervalSince($0) } ?? 3600
            if age > 120 { try? fileManager.removeItem(at: url) }
        }
        return try Upload(folder: gameFolder, length: length, fileManager: fileManager)
    }

    // MARK: giving copies back

    /// The copies of a game this Mac holds, the ones it named itself (`SaveUpload.isCopyName`), newest first. A file the player
    /// put in the folder is not one, and is never listed or served.
    func copies(titleID: String) throws -> [(name: String, size: Int64)] {
        guard accepting() else { throw Refusal.off }
        guard TitleID.isGame(titleID), let id = TitleID(titleID) else { throw Refusal.notAGame }
        let folder = SaveBackup.folder(of: id.description, in: outputFolder())
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(SaveUpload.isCopyName).compactMap { name -> (String, Int64)? in
            let attributes = try? fileManager.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular, let size = attributes?[.size] as? Int64,
                  size > 0, size <= SaveUpload.maxBytes else { return nil }
            return (name, size)
        }
        .sorted { $0.0 > $1.0 }
    }

    /// One copy, opened for reading by descriptor: a name that is not one this Mac made, a link and anything that is not a file of
    /// a sane size are not served.
    func open(titleID: String, name: String) throws -> OpenedFile {
        guard accepting() else { throw Refusal.off }
        guard TitleID.isGame(titleID), let id = TitleID(titleID), SaveUpload.isCopyName(name) else { throw Refusal.notAGame }
        let path = SaveBackup.folder(of: id.description, in: outputFolder()).appendingPathComponent(name).path
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Refusal.notAGame }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, Int64(info.st_size) <= SaveUpload.maxBytes else {
            Darwin.close(descriptor)
            throw Refusal.notAGame
        }
        return OpenedFile(descriptor: descriptor, size: Int64(info.st_size))
    }

    /// One copy on its way in.
    final class Upload {
        static let prefix = ".upload-"
        private let folder: URL
        private let temporary: URL
        private let length: Int64
        private let handle: FileHandle
        private let fileManager: FileManager
        private var written: Int64 = 0
        private var head = Data()

        init(folder: URL, length: Int64, fileManager: FileManager) throws {
            self.folder = folder
            self.length = length
            self.fileManager = fileManager
            temporary = folder.appendingPathComponent(Self.prefix + UUID().uuidString)
            guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NXPocketError(.transferFailed, "a file for the saves could not be made")
            }
            handle = try FileHandle(forWritingTo: temporary)
        }

        /// More of the body than was announced is refused: a phone that keeps sending is not the one that sent the header.
        func write(_ data: Data) throws {
            guard written + Int64(data.count) <= length else { abort(); throw Refusal.tooLarge }
            if head.count < SaveUpload.zipMagic.count {
                head.append(data.prefix(SaveUpload.zipMagic.count - head.count))
                if head.count == SaveUpload.zipMagic.count, head != SaveUpload.zipMagic { abort(); throw Refusal.notAZip }
            }
            do { try handle.write(contentsOf: data) } catch { abort(); throw error }
            written += Int64(data.count)
        }

        /// Renames the copy to its name and drops the oldest ones. Returns the file.
        func commit(now: Date = Date()) throws -> URL {
            defer { try? handle.close() }
            guard written == length else { abort(); throw Refusal.cut }
            try handle.synchronize()
            var name = SaveUpload.fileName(at: now)
            var index = 2
            while fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) {
                name = String(SaveUpload.fileName(at: now).dropLast(4)) + " \(index).zip"
                index += 1
            }
            let final = folder.appendingPathComponent(name)
            do { try fileManager.moveItem(at: temporary, to: final) } catch { abort(); throw error }
            let copies = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter(SaveUpload.isCopyName).sorted(by: >)
            for old in copies.dropFirst(SaveUpload.keep) { try? fileManager.removeItem(at: folder.appendingPathComponent(old)) }
            return final
        }

        func abort() {
            try? handle.close()
            try? fileManager.removeItem(at: temporary)
        }
    }
}
