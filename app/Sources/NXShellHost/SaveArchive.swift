import Compression
import Foundation
import NXPocketKit

/// The .zip of a save export, made by the system (`NSFileCoordinator` zips a folder it is asked to read "for
/// uploading"), and read back here: iOS has no public way to open a .zip. Only what a save copy needs: stored and
/// deflated entries, no encryption, no zip64. Every size comes from the central directory, so an entry written with a
/// data descriptor (as Finder and the system write them) reads too, and every entry's CRC is checked. The archive is
/// mapped, never read whole, and each entry goes to its file a megabyte at a time, so a large entry costs no memory.
enum SaveArchive {
    enum Failure: Error, Equatable {
        case damaged(String)
        case unsupported(String)
        case tooLarge
    }

    /// Zips `folder`, the folder itself at the root of the archive, into `destination`.
    static func zip(folder: URL, to destination: URL, fileManager: FileManager = .default) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do { try fileManager.copyItem(at: zipped, to: destination) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }

    /// Whether a file starts the way a .zip does, whatever its name.
    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    struct Entry: Equatable {
        var path: String
        var method: UInt16
        var flags: UInt16
        var crc: UInt32
        var compressedSize: Int
        var size: Int
        var localOffset: Int
        var isLink: Bool

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    /// Writes every file of the archive under `folder`. Folders come from the files' paths; links, Finder's
    /// `__MACOSX` copies, `._` files and `.DS_Store` are left out. Refuses a path that would leave `folder`, and an
    /// archive or a content larger than `maxBytes`, before anything is written.
    static func extract(_ zip: URL, into folder: URL, maxBytes: Int64 = 2 << 30,
                        fileManager: FileManager = .default) throws {
        let size = (try? fileManager.attributesOfItem(atPath: zip.path))?[.size] as? Int64 ?? 0
        guard size <= maxBytes + (16 << 20) else { throw Failure.tooLarge }
        let data = try Data(contentsOf: zip, options: .alwaysMapped)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let entries = try centralDirectory(raw).filter { !$0.isDirectory && !$0.isLink && !isFinderLeftover($0.path) }
            guard entries.reduce(Int64(0), { $0 + Int64($1.size) }) <= maxBytes else { throw Failure.tooLarge }
            for entry in entries where !SafePath.isSafeRelative(entry.path) {
                throw Failure.damaged("unsafe path \(entry.path)")
            }
            for entry in entries {
                let target = folder.appendingPathComponent(entry.path)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write(entry, from: raw, to: target, fileManager: fileManager)
            }
        }
    }

    static func isFinderLeftover(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return path.hasPrefix("__MACOSX/") || name.hasPrefix("._") || name == ".DS_Store"
    }

    // MARK: - The format

    static func centralDirectory(_ raw: UnsafeRawBufferPointer) throws -> [Entry] {
        guard raw.count >= 22 else { throw Failure.damaged("too short to be a .zip") }
        // The end record sits in the last 22 bytes plus at most a 65535-byte comment.
        var end = -1
        var offset = raw.count - 22
        let lowest = max(0, raw.count - 22 - 0xFFFF)
        while offset >= lowest {
            if u32(raw, offset) == 0x0605_4B50 { end = offset; break }
            offset -= 1
        }
        guard end >= 0 else { throw Failure.damaged("no end of central directory") }
        let count = Int(u16(raw, end + 10))
        let size = Int(u32(raw, end + 12))
        let start = Int(u32(raw, end + 16))
        guard count != 0xFFFF, start != 0xFFFF_FFFF, size != 0xFFFF_FFFF else { throw Failure.unsupported("zip64") }
        guard start + size <= end else { throw Failure.damaged("central directory out of bounds") }
        var entries: [Entry] = []
        var cursor = start
        for _ in 0..<count {
            guard cursor + 46 <= end, u32(raw, cursor) == 0x0201_4B50 else { throw Failure.damaged("bad central directory entry") }
            let nameLength = Int(u16(raw, cursor + 28))
            let extraLength = Int(u16(raw, cursor + 30))
            let commentLength = Int(u16(raw, cursor + 32))
            guard cursor + 46 + nameLength <= end else { throw Failure.damaged("entry name out of bounds") }
            let name = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(cursor + 46)..<(cursor + 46 + nameLength)]), as: UTF8.self)
            let madeBy = u16(raw, cursor + 4) >> 8
            let mode = u32(raw, cursor + 38) >> 16
            let entry = Entry(path: name, method: u16(raw, cursor + 10), flags: u16(raw, cursor + 8), crc: u32(raw, cursor + 16),
                              compressedSize: Int(u32(raw, cursor + 20)), size: Int(u32(raw, cursor + 24)),
                              localOffset: Int(u32(raw, cursor + 42)), isLink: madeBy == 3 && mode & 0xF000 == 0xA000)
            guard entry.size != 0xFFFF_FFFF, entry.compressedSize != 0xFFFF_FFFF, entry.localOffset != 0xFFFF_FFFF else {
                throw Failure.unsupported("zip64")
            }
            entries.append(entry)
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static let chunk = 1 << 20

    /// One entry into its file, inflated a chunk at a time, its size and CRC checked as it goes.
    static func write(_ entry: Entry, from raw: UnsafeRawBufferPointer, to target: URL, fileManager: FileManager) throws {
        guard entry.flags & 1 == 0 else { throw Failure.unsupported("encrypted entry \(entry.path)") }
        let header = entry.localOffset
        guard header + 30 <= raw.count, u32(raw, header) == 0x0403_4B50 else { throw Failure.damaged("bad local header for \(entry.path)") }
        let start = header + 30 + Int(u16(raw, header + 26)) + Int(u16(raw, header + 28))
        guard start + entry.compressedSize <= raw.count else { throw Failure.damaged("\(entry.path) is cut short") }
        let source = UnsafeRawBufferPointer(rebasing: raw[start..<(start + entry.compressedSize)])
        guard fileManager.createFile(atPath: target.path, contents: nil), let handle = FileHandle(forWritingAtPath: target.path) else {
            throw Failure.damaged("\(entry.path) could not be written")
        }
        defer { try? handle.close() }
        var crc = CRC32.start
        var written = 0
        let take: (UnsafeRawBufferPointer) throws -> Void = { piece in
            written += piece.count
            guard written <= entry.size else { throw Failure.damaged("\(entry.path) is larger than it says") }
            crc = CRC32.update(crc, piece)
            try handle.write(contentsOf: Data(piece))
        }
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw Failure.damaged("\(entry.path) has two sizes") }
            var offset = 0
            while offset < source.count {
                let end = min(offset + chunk, source.count)
                try take(UnsafeRawBufferPointer(rebasing: source[offset..<end]))
                offset = end
            }
        case 8:
            try inflate(source, path: entry.path, take)
        default:
            throw Failure.unsupported("compression method \(entry.method) for \(entry.path)")
        }
        guard written == entry.size, CRC32.finish(crc) == entry.crc else { throw Failure.damaged("\(entry.path) fails its checksum") }
    }

    /// Raw deflate, which is what the Compression framework's "zlib" reads (no zlib header), a chunk at a time.
    static func inflate(_ source: UnsafeRawBufferPointer, path: String, _ take: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard source.count > 0, let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.damaged("\(path) could not be inflated")
        }
        defer { compression_stream_destroy(stream) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        stream.pointee.src_ptr = UnsafePointer(base)
        stream.pointee.src_size = source.count
        var status: compression_status
        repeat {
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = chunk
            status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            guard status != COMPRESSION_STATUS_ERROR else { throw Failure.damaged("\(path) does not inflate") }
            let produced = chunk - stream.pointee.dst_size
            if produced > 0 { try take(UnsafeRawBufferPointer(start: buffer, count: produced)) }
        } while status == COMPRESSION_STATUS_OK
    }

    static func u16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

/// The zip format's CRC-32 (IEEE, reflected).
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static let start: UInt32 = 0xFFFF_FFFF

    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc = crc
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc
    }

    static func finish(_ crc: UInt32) -> UInt32 { crc ^ 0xFFFF_FFFF }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 { finish(update(start, bytes)) }
}
