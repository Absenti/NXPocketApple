import Foundation

/// A tar read as it comes (a push parser: `.tar` feeds it the file, `.tar.gz` the inflated stream), with ustar, GNU long names and pax
/// paths and sizes. Files and folders only: a link, a device or a pipe is refused, as a path that leaves the folder is.
final class TarExtractor {
    private enum Phase {
        case header
        case skip(Int)
        case file(handle: FileHandle, left: UInt64, padding: Int)
        /// The body of a GNU long name (`L`) or a pax record (`x`): small, held whole.
        case meta(kind: UInt8, left: Int, padding: Int)
    }

    private let sink: ArchiveExtractor.Sink
    private var buffer = Data()
    private var phase = Phase.header
    private var meta = Data()
    /// A long name or a pax path, for the entry that follows; and a pax size.
    private var nextName: String?
    private var nextSize: UInt64?
    private var zeroBlocks = 0
    private var ended = false

    init(sink: ArchiveExtractor.Sink) { self.sink = sink }

    func feed(_ data: Data) throws {
        guard !ended else { return }
        buffer.append(data)
        try process()
    }

    /// The end of the stream: a tar that stops anywhere but between entries is cut short.
    func finish() throws {
        try process()
        if case .file(let handle, _, _) = phase { try? handle.close(); throw NXPocketError(.packageDamaged, "the archive ends before it is whole") }
        if case .meta = phase { throw NXPocketError(.packageDamaged, "the archive ends before it is whole") }
        if case .skip(let count) = phase, count > 0, !ended { throw NXPocketError(.packageDamaged, "the archive ends before it is whole") }
        if !ended, !buffer.allSatisfy({ $0 == 0 }) { throw NXPocketError(.packageDamaged, "the archive ends before it is whole") }
    }

    private func process() throws {
        while !ended {
            switch phase {
            case .skip(let count):
                let take = min(count, buffer.count)
                buffer = Data(buffer.dropFirst(take))
                phase = count - take > 0 ? .skip(count - take) : .header
                if take == 0 && count > 0 { return }
            case .file(let handle, let left, let padding):
                let take = Int(min(UInt64(buffer.count), left))
                if take > 0 {
                    try handle.write(contentsOf: buffer.prefix(take))
                    try sink.wrote(take)
                    buffer = Data(buffer.dropFirst(take))
                }
                if UInt64(take) == left {
                    try handle.close()
                    phase = padding > 0 ? .skip(padding) : .header
                } else {
                    phase = .file(handle: handle, left: left - UInt64(take), padding: padding)
                    return
                }
            case .meta(let kind, let left, let padding):
                let take = min(left, buffer.count)
                meta.append(buffer.prefix(take))
                buffer = Data(buffer.dropFirst(take))
                if take == left {
                    readMeta(kind)
                    phase = padding > 0 ? .skip(padding) : .header
                } else {
                    phase = .meta(kind: kind, left: left - take, padding: padding)
                    return
                }
            case .header:
                guard buffer.count >= 512 else { return }
                let header = Data(buffer.prefix(512))
                buffer = Data(buffer.dropFirst(512))
                try parse(header)
            }
        }
    }

    private func parse(_ header: Data) throws {
        if header.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks >= 2 { ended = true }
            return
        }
        zeroBlocks = 0
        // The checksum is the sum of the header's bytes with its own field taken as spaces.
        var sum = 0
        for (index, byte) in header.enumerated() { sum += (148..<156).contains(index) ? 32 : Int(byte) }
        guard let stored = Self.octal(header, 148, 8), Int(stored) == sum else {
            throw NXPocketError(.packageDamaged, "the archive is damaged (a header does not match its checksum)")
        }
        let type = header[header.startIndex + 156] == 0 ? UInt8(ascii: "0") : header[header.startIndex + 156]
        var size = Self.number(header, 124, 12) ?? 0
        if let nextSize { size = nextSize }
        var name = Self.string(header, 0, 100)
        if Self.string(header, 257, 6).hasPrefix("ustar") {
            let prefix = Self.string(header, 345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        if let nextName { name = nextName }
        let padding = Int((512 - size % 512) % 512)

        switch type {
        case UInt8(ascii: "L"), UInt8(ascii: "x"):
            // The record sets the name or size of the entry after it, so they are kept past this header.
            guard size <= 1 << 20 else { throw NXPocketError(.packageDamaged, "the archive has a header record that is too large") }
            meta = Data()
            phase = size == 0 ? .header : .meta(kind: type, left: Int(size), padding: padding)
        case UInt8(ascii: "g"), UInt8(ascii: "K"):
            phase = size + UInt64(padding) > 0 ? .skip(Int(size) + padding) : .header
        case UInt8(ascii: "0"), UInt8(ascii: "7"):
            nextName = nil; nextSize = nil
            guard let path = try sink.accept(name) else {
                phase = size + UInt64(padding) > 0 ? .skip(Int(size) + padding) : .header
                return
            }
            let handle = try sink.open(file: path)
            if size == 0 { try handle.close(); return }
            phase = .file(handle: handle, left: size, padding: padding)
        case UInt8(ascii: "5"):
            nextName = nil; nextSize = nil
            if let path = try sink.accept(name) { try sink.makeFolder(path) }
        case UInt8(ascii: "1"), UInt8(ascii: "2"):
            throw NXPocketError(.symbolicLink, "the archive holds a link (\"\(name)\"): a build holds none", path: name)
        default:
            throw NXPocketError(.packageDamaged, "the archive holds an entry that is not a file or a folder (\"\(name)\")", path: name)
        }
    }

    private func readMeta(_ kind: UInt8) {
        if kind == UInt8(ascii: "L") {
            nextName = String(decoding: meta.prefix { $0 != 0 }, as: UTF8.self)
            return
        }
        // pax: "<length> <key>=<value>\n" records.
        var text = meta
        while !text.isEmpty {
            guard let space = text.firstIndex(of: 0x20),
                  let length = Int(String(decoding: text[text.startIndex..<space], as: UTF8.self)),
                  length > 0, length <= text.count else { break }
            let record = text[(space + 1)..<(text.startIndex + length)]
            if let equals = record.firstIndex(of: 0x3D) {
                let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
                let value = String(decoding: record[(equals + 1)...].dropLast(), as: UTF8.self)
                if key == "path" { nextName = value }
                if key == "size", let number = UInt64(value) { nextSize = number }
            }
            text = Data(text.dropFirst(length))
        }
    }

    // MARK: header fields

    private static func string(_ header: Data, _ at: Int, _ length: Int) -> String {
        String(decoding: header[(header.startIndex + at)..<(header.startIndex + at + length)].prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func octal(_ header: Data, _ at: Int, _ length: Int) -> UInt64? {
        let text = string(header, at, length).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        return text.isEmpty ? 0 : UInt64(text, radix: 8)
    }

    /// A size: octal, or base-256 (a high bit in the first byte) for a file over 8 GiB, which a RomFS image can be.
    private static func number(_ header: Data, _ at: Int, _ length: Int) -> UInt64? {
        let first = header[header.startIndex + at]
        guard first & 0x80 != 0 else { return octal(header, at, length) }
        var value = UInt64(first & 0x7F)
        for index in 1..<length {
            guard value >> 56 == 0 else { return nil }
            value = value << 8 | UInt64(header[header.startIndex + at + index])
        }
        return value
    }
}
