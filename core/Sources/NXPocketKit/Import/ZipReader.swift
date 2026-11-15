import Foundation
import zlib

/// A .zip read from its central directory, with zip64, and unpacked through `ArchiveExtractor.Sink`. Every size comes from the central
/// directory (an entry written with a data descriptor has no size in its local header), and every entry's checksum is checked. Stored and
/// deflated entries only; an encrypted one, or one of another method, is refused by name.
final class ZipReader {
    struct Entry {
        var path: String
        var method: UInt16
        var flags: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var offset: UInt64
        var madeBy: UInt16
        var attributes: UInt32
        var isDirectory: Bool { path.hasSuffix("/") }
        /// Unix mode bits live in the top half of the external attributes when the archive was made on Unix or macOS.
        var isLink: Bool { madeBy >> 8 == 3 && (attributes >> 16) & 0xF000 == 0xA000 }
    }

    private let handle: FileHandle
    private let fileSize: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = UInt64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
    }

    deinit { try? handle.close() }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw NXPocketError(.packageDamaged, "the archive ends before it is whole")
        }
        return data
    }

    private static func u16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[data.startIndex + at]) | UInt16(data[data.startIndex + at + 1]) << 8 }
    private static func u32(_ data: Data, _ at: Int) -> UInt32 { UInt32(u16(data, at)) | UInt32(u16(data, at + 2)) << 16 }
    private static func u64(_ data: Data, _ at: Int) -> UInt64 { UInt64(u32(data, at)) | UInt64(u32(data, at + 4)) << 32 }

    // MARK: the central directory

    func entries() throws -> [Entry] {
        guard fileSize >= 22 else { throw NXPocketError(.packageDamaged, "the archive is too short to be a .zip") }
        // The end record is in the last 64 KiB and 22 bytes, behind a comment of any length.
        let tailLength = Int(min(fileSize, 65_557))
        let tail = try read(at: fileSize - UInt64(tailLength), count: tailLength)
        var endAt: Int?
        var index = tailLength - 22
        while index >= 0 {
            if Self.u32(tail, index) == 0x0605_4B50 { endAt = index; break }
            index -= 1
        }
        guard let end = endAt else { throw NXPocketError(.packageDamaged, "the archive has no end record: it is cut short, or not a .zip") }
        var count = UInt64(Self.u16(tail, end + 10))
        var directorySize = UInt64(Self.u32(tail, end + 12))
        var directoryOffset = UInt64(Self.u32(tail, end + 16))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // zip64: the locator sits just before the end record and points at the zip64 end record.
            let locatorAt = Int(fileSize) - tailLength + end - 20
            guard locatorAt >= 0 else { throw NXPocketError(.packageDamaged, "the zip64 locator is missing") }
            let locator = try read(at: UInt64(locatorAt), count: 20)
            guard Self.u32(locator, 0) == 0x0706_4B50 else { throw NXPocketError(.packageDamaged, "the zip64 locator is missing") }
            let record = try read(at: Self.u64(locator, 8), count: 56)
            guard Self.u32(record, 0) == 0x0606_4B50 else { throw NXPocketError(.packageDamaged, "the zip64 end record is damaged") }
            count = Self.u64(record, 32)
            directorySize = Self.u64(record, 40)
            directoryOffset = Self.u64(record, 48)
        }
        guard count <= UInt64(SharingLimits.maxFilesPerGame) * 2, directorySize <= 256 << 20,
              directoryOffset + directorySize <= fileSize else {
            throw NXPocketError(.packageDamaged, "the archive's directory is damaged or too large")
        }
        let directory = try read(at: directoryOffset, count: Int(directorySize))
        var entries: [Entry] = []
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= directory.count, Self.u32(directory, at) == 0x0201_4B50 else {
                throw NXPocketError(.packageDamaged, "the archive's directory is damaged")
            }
            let madeBy = Self.u16(directory, at + 4)
            let flags = Self.u16(directory, at + 8)
            let method = Self.u16(directory, at + 10)
            let crc = Self.u32(directory, at + 16)
            var compressed = UInt64(Self.u32(directory, at + 20))
            var size = UInt64(Self.u32(directory, at + 24))
            let nameLength = Int(Self.u16(directory, at + 28)), extraLength = Int(Self.u16(directory, at + 30)), commentLength = Int(Self.u16(directory, at + 32))
            let attributes = Self.u32(directory, at + 38)
            var offset = UInt64(Self.u32(directory, at + 42))
            guard at + 46 + nameLength + extraLength + commentLength <= directory.count else {
                throw NXPocketError(.packageDamaged, "the archive's directory is damaged")
            }
            let nameData = directory.subdata(in: (directory.startIndex + at + 46)..<(directory.startIndex + at + 46 + nameLength))
            let path = flags & 0x800 != 0 ? String(decoding: nameData, as: UTF8.self) : (String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "")
            // The zip64 extra field holds, in this order, only the values the 32-bit fields could not.
            var extra = directory.subdata(in: (directory.startIndex + at + 46 + nameLength)..<(directory.startIndex + at + 46 + nameLength + extraLength))
            while extra.count >= 4 {
                let id = Self.u16(extra, 0), length = Int(Self.u16(extra, 2))
                guard 4 + length <= extra.count else { break }
                if id == 0x0001 {
                    var field = 4
                    if size == 0xFFFF_FFFF, field + 8 <= 4 + length { size = Self.u64(extra, field); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= 4 + length { compressed = Self.u64(extra, field); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= 4 + length { offset = Self.u64(extra, field); field += 8 }
                }
                extra = extra.subdata(in: (extra.startIndex + 4 + length)..<extra.endIndex)
            }
            entries.append(Entry(path: path, method: method, flags: flags, crc: crc, compressedSize: compressed, size: size, offset: offset,
                                 madeBy: madeBy, attributes: attributes))
            at += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: unpacking

    func extract(into sink: ArchiveExtractor.Sink) throws {
        let all = try entries()
        // Everything that can be known before a byte is written is checked first: the unsafe, the unsupported and the too big.
        var wanted: [(entry: Entry, path: String)] = []
        var total: UInt64 = 0
        for entry in all {
            guard let path = try sink.accept(entry.path) else { continue }
            if entry.isDirectory { wanted.append((entry, path)); continue }
            if entry.isLink { throw NXPocketError(.symbolicLink, "the archive holds a link (\"\(entry.path)\"): a build holds none", path: entry.path) }
            if entry.flags & 1 != 0 { throw NXPocketError(.packageUnsupported, "the archive is encrypted: unpack it with its password and make a plain .zip") }
            guard entry.method == 0 || entry.method == 8 else {
                throw NXPocketError(.packageUnsupported, "\"\(entry.path)\" is compressed with method \(entry.method), which is not supported: make the archive with deflate or store")
            }
            guard entry.method == 8 || entry.compressedSize == entry.size else {
                throw NXPocketError(.packageDamaged, "\"\(entry.path)\" is stored with two sizes", path: entry.path)
            }
            total += entry.size
            guard total <= UInt64(SharingLimits.maxGameBytes) else { throw NXPocketError(.packageDamaged, "the archive holds more than \(SharingLimits.maxGameBytes) bytes") }
            wanted.append((entry, path))
        }
        guard wanted.filter({ !$0.entry.isDirectory }).count <= SharingLimits.maxFilesPerGame else {
            throw NXPocketError(.packageDamaged, "the archive holds more than \(SharingLimits.maxFilesPerGame) files")
        }
        if let free = sink.availableSpace(), Int64(clamping: total) + sink.headroom > free {
            throw NXPocketError(.notEnoughSpace, "\(GameImporter.bytes(Int64(clamping: total) + sink.headroom)) needed, \(GameImporter.bytes(free)) free")
        }
        sink.expectedTotal = Int64(clamping: total)
        for item in wanted {
            if item.entry.isDirectory { try sink.makeFolder(item.path) } else { try unpack(item.entry, as: item.path, into: sink) }
        }
    }

    private func unpack(_ entry: Entry, as path: String, into sink: ArchiveExtractor.Sink) throws {
        let local = try read(at: entry.offset, count: 30)
        guard Self.u32(local, 0) == 0x0403_4B50 else { throw NXPocketError(.packageDamaged, "\"\(entry.path)\" is not where the directory says", path: entry.path) }
        let dataStart = entry.offset + 30 + UInt64(Self.u16(local, 26)) + UInt64(Self.u16(local, 28))
        guard dataStart + entry.compressedSize <= fileSize else { throw NXPocketError(.packageDamaged, "\"\(entry.path)\" is cut short", path: entry.path) }
        let output = try sink.open(file: path)
        defer { try? output.close() }
        var crc = crc32(0, nil, 0)
        var written: UInt64 = 0

        func emit(_ bytes: UnsafeRawBufferPointer) throws {
            guard written + UInt64(bytes.count) <= entry.size else {
                throw NXPocketError(.sizeMismatch, "\"\(entry.path)\" is longer than its header says", path: entry.path)
            }
            crc = crc32(crc, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count))
            try output.write(contentsOf: Data(bytes))
            written += UInt64(bytes.count)
            try sink.wrote(bytes.count)
        }

        var position = dataStart
        var left = entry.compressedSize
        if entry.method == 0 {
            while left > 0 {
                let chunk = try read(at: position, count: Int(min(left, 1 << 20)))
                try chunk.withUnsafeBytes { try emit($0) }
                position += UInt64(chunk.count)
                left -= UInt64(chunk.count)
            }
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw NXPocketError(.packageDamaged, "\"\(entry.path)\" could not be opened", path: entry.path)
            }
            defer { inflateEnd(&stream) }
            var out = [UInt8](repeating: 0, count: 1 << 20)
            var status: Int32 = Z_OK
            while status != Z_STREAM_END {
                guard left > 0 else { throw NXPocketError(.packageDamaged, "\"\(entry.path)\" ends before its data does", path: entry.path) }
                var input = [UInt8](try read(at: position, count: Int(min(left, 1 << 20))))
                position += UInt64(input.count)
                left -= UInt64(input.count)
                try input.withUnsafeMutableBufferPointer { buffer in
                    stream.next_in = buffer.baseAddress
                    stream.avail_in = UInt32(buffer.count)
                    while stream.avail_in > 0 && status != Z_STREAM_END {
                        let produced: Int = try out.withUnsafeMutableBufferPointer { window in
                            stream.next_out = window.baseAddress
                            stream.avail_out = UInt32(window.count)
                            status = inflate(&stream, Z_NO_FLUSH)
                            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                                throw NXPocketError(.packageDamaged, "\"\(entry.path)\" is damaged (deflate error \(status))", path: entry.path)
                            }
                            return window.count - Int(stream.avail_out)
                        }
                        if produced > 0 { try out.withUnsafeBytes { try emit(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) } }
                        if produced == 0 && status == Z_BUF_ERROR { break }
                    }
                }
            }
        }
        guard written == entry.size else {
            throw NXPocketError(.sizeMismatch, "\"\(entry.path)\" is \(written) bytes, its header says \(entry.size)", path: entry.path)
        }
        guard UInt32(truncatingIfNeeded: crc) == entry.crc else {
            throw NXPocketError(.hashMismatch, "\"\(entry.path)\" does not match its checksum: the archive is damaged", path: entry.path)
        }
    }
}
