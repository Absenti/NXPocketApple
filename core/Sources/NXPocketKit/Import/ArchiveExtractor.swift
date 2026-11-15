import Foundation
import zlib

/// Unpacks a game build that arrived as one archive: `.zip` (with zip64: a RomFS image is far over 4 GB), `.tar` and `.tar.gz`. The
/// archive is a stranger's bytes, so everything it says is bounded and checked before it is believed: no path may leave the folder,
/// no link, device or encrypted entry is unpacked, a name that a volume ignoring case would merge with another is refused, a file
/// that is longer than its header said stops, a checksum that does not match stops, and the space is checked before a byte is
/// written (known exactly for a zip, watched as it goes for a tar). Nothing is read whole: a file goes through a megabyte at a time.
public enum ArchiveExtractor {
    public enum Format: Equatable, Sendable {
        case zip, tar, tarGzip
        /// Recognised, and said not to be supported, rather than failing with a message about bytes.
        case sevenZip, rar, bzip2, xz, zstd
        case unknown
    }

    public struct Report: Equatable, Sendable {
        public var files: Int
        public var bytes: Int64
    }

    /// 7z and RAR are not read: their decoders are not in the system, 7z needs LZMA and RAR is a proprietary format.
    public static func unsupported(_ format: Format) -> NXPocketError? {
        switch format {
        case .sevenZip: return NXPocketError(.packageUnsupported, "7z archives are not supported: make the archive a .zip or a .tar.gz")
        case .rar: return NXPocketError(.packageUnsupported, "RAR archives are not supported (RAR is a proprietary format): make the archive a .zip or a .tar.gz")
        case .bzip2: return NXPocketError(.packageUnsupported, "bzip2 archives are not supported: make the archive a .zip or a .tar.gz")
        case .xz: return NXPocketError(.packageUnsupported, "xz archives are not supported: make the archive a .zip or a .tar.gz")
        case .zstd: return NXPocketError(.packageUnsupported, "zstd archives are not supported: make the archive a .zip or a .tar.gz")
        case .unknown: return NXPocketError(.packageDamaged, "this is not an archive this app can open (.zip, .tar, .tar.gz)")
        case .zip, .tar, .tarGzip: return nil
        }
    }

    /// The format, by the first bytes and never by the name.
    public static func detect(_ url: URL) -> Format {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count >= 4 else { return .unknown }
        let bytes = [UInt8](head)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if bytes.starts(with: [0x1F, 0x8B]) { return .tarGzip }
        if bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if bytes.starts(with: Array("Rar!".utf8)) { return .rar }
        if bytes.starts(with: Array("BZh".utf8)) { return .bzip2 }
        if bytes.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if bytes.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        try? handle.seek(toOffset: 257)
        if let magic = try? handle.read(upToCount: 5), magic == Data("ustar".utf8) { return .tar }
        return .unknown
    }

    /// Unpacks `archive` into `folder` (which must exist and be empty). `availableSpace` is the free space of the volume, nil when it
    /// is not checked. A failure leaves what was written: the caller removes the folder.
    @discardableResult
    public static func extract(_ archive: URL, into folder: URL, availableSpace: @escaping () -> Int64? = { nil },
                               headroom: Int64 = 1 << 30, progress: @escaping (Double) -> Void = { _ in }) throws -> Report {
        let format = detect(archive)
        if let refusal = unsupported(format) { throw refusal }
        let sink = Sink(folder: folder, availableSpace: availableSpace, headroom: headroom, progress: progress)
        switch format {
        case .zip:
            try ZipReader(url: archive).extract(into: sink)
        case .tar:
            let tar = TarExtractor(sink: sink)
            try feed(archive, to: { try tar.feed($0) })
            try tar.finish()
        case .tarGzip:
            let tar = TarExtractor(sink: sink)
            let total = Double((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 1)
            var read: Int64 = 0
            try gunzip(archive, onInput: { read += Int64($0); progress(min(Double(read) / max(total, 1), 1)) }, to: { try tar.feed($0) })
            try tar.finish()
        default:
            break
        }
        return Report(files: sink.files, bytes: sink.bytes)
    }

    // MARK: reading

    static func feed(_ url: URL, to consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
            try consume(chunk)
        }
    }

    /// gzip through zlib, a megabyte at a time. Members one after another are read as one stream.
    static func gunzip(_ url: URL, onInput: (Int) -> Void, to consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NXPocketError(.packageDamaged, "the archive could not be opened")
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 1 << 20)
        var status: Int32 = Z_OK
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
            onInput(chunk.count)
            var input = [UInt8](chunk)
            try input.withUnsafeMutableBufferPointer { buffer in
                stream.next_in = buffer.baseAddress
                stream.avail_in = UInt32(buffer.count)
                while stream.avail_in > 0 {
                    if status == Z_STREAM_END {
                        // Another member follows.
                        inflateReset(&stream)
                        status = Z_OK
                    }
                    let produced: Int = try output.withUnsafeMutableBufferPointer { out in
                        stream.next_out = out.baseAddress
                        stream.avail_out = UInt32(out.count)
                        status = inflate(&stream, Z_NO_FLUSH)
                        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                            throw NXPocketError(.packageDamaged, "the archive is damaged (gzip error \(status))")
                        }
                        return out.count - Int(stream.avail_out)
                    }
                    if produced > 0 { try consume(Data(output[0..<produced])) }
                    if status == Z_BUF_ERROR && produced == 0 { break }
                }
            }
        }
        guard status == Z_STREAM_END else { throw NXPocketError(.packageDamaged, "the archive ends before it is whole") }
    }

    // MARK: where the files go

    /// The folder being filled, and what it may take: every file is made through here, so the rules are in one place.
    final class Sink {
        let folder: URL
        let availableSpace: () -> Int64?
        let headroom: Int64
        let progress: (Double) -> Void
        private(set) var files = 0
        private(set) var bytes: Int64 = 0
        private var seen = Set<String>()
        private var folders = Set<String>()
        private var sinceSpaceCheck: Int64 = 0
        /// Known for a zip, nil for a tar.
        var expectedTotal: Int64?

        init(folder: URL, availableSpace: @escaping () -> Int64?, headroom: Int64, progress: @escaping (Double) -> Void) {
            self.folder = folder
            self.availableSpace = availableSpace
            self.headroom = headroom
            self.progress = progress
        }

        /// The path an entry may be written at, or nil for what is left out (the Finder's files). A refusal for anything unsafe.
        func accept(_ rawPath: String) throws -> String? {
            var path = rawPath
            while path.hasPrefix("./") { path.removeFirst(2) }
            if path.hasSuffix("/") { path.removeLast() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.contains("__MACOSX") || parts.contains(where: { PackageScanner.isFinderMetadata($0) }) { return nil }
            // The markers of a transfer are the phone's own word, written by it last: an archive's are never unpacked, so one cannot
            // make a half-unpacked folder look complete.
            if parts.count == 1, GameArchiveImporter.markers.contains(path) { return nil }
            guard !path.isEmpty, SafePath.isSafeRelative(path) else {
                throw NXPocketError(.unsafePath, "the archive holds \"\(rawPath)\", a path that leaves the folder it is unpacked in", path: rawPath)
            }
            return path
        }

        /// A name a volume that ignores case and Unicode form would merge with another, or a file standing where a folder goes.
        func claim(file path: String) throws {
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted, !folders.contains(key) else {
                throw NXPocketError(.packageInconsistent, "\"\(path)\" collides with another name of the archive", path: path)
            }
            var prefix = ""
            for part in key.split(separator: "/").dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + part
                guard !seen.contains(prefix) else { throw NXPocketError(.packageInconsistent, "\"\(path)\" sits under a file of the same name", path: path) }
                folders.insert(prefix)
            }
        }

        func makeFolder(_ path: String) throws {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
        }

        /// Where a file will be written, for a copy that makes the file itself (a clone): the name is claimed and its folder made.
        func destination(for path: String) throws -> URL {
            try claim(file: path)
            guard files < SharingLimits.maxFilesPerGame else {
                throw NXPocketError(.packageDamaged, "there are more than \(SharingLimits.maxFilesPerGame) files")
            }
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            files += 1
            return url
        }

        func open(file path: String) throws -> FileHandle {
            try claim(file: path)
            guard files < SharingLimits.maxFilesPerGame else {
                throw NXPocketError(.packageDamaged, "the archive holds more than \(SharingLimits.maxFilesPerGame) files")
            }
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw NXPocketError(.transferFailed, "\"\(path)\" could not be written", path: path)
            }
            files += 1
            return try FileHandle(forWritingTo: url)
        }

        /// Bytes that were written without going through `wrote` one chunk at a time (a clone): counted, and the limits applied.
        func account(_ count: Int64) throws {
            bytes += count
            guard bytes <= SharingLimits.maxGameBytes else { throw NXPocketError(.packageDamaged, "more than \(SharingLimits.maxGameBytes) bytes") }
            if let total = expectedTotal, total > 0 { progress(min(Double(bytes) / Double(total), 1)) }
            if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
        }

        func wrote(_ count: Int) throws {
            bytes += Int64(count)
            sinceSpaceCheck += Int64(count)
            guard bytes <= SharingLimits.maxGameBytes else { throw NXPocketError(.packageDamaged, "the archive holds more than \(SharingLimits.maxGameBytes) bytes") }
            if sinceSpaceCheck >= 64 << 20 {
                sinceSpaceCheck = 0
                if let free = availableSpace(), free < headroom { throw NXPocketError(.notEnoughSpace, "the volume is full (\(GameImporter.bytes(free)) free)") }
            }
            if let total = expectedTotal, total > 0 { progress(min(Double(bytes) / Double(total), 1)) }
            if Task.isCancelled { throw NXPocketError(.cancelled, "stopped") }
        }
    }
}
