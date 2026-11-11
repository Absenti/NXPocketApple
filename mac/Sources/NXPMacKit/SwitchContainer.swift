import Foundation

/// A package file read in place, a few bytes at a time: a base game is gigabytes and only its headers are wanted.
final class PackageFileReader {
    let url: URL
    let size: UInt64
    private let handle: FileHandle

    init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw SwitchFormatError("\(url.lastPathComponent) ends before the \(count) bytes at \(offset)")
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw SwitchFormatError("\(url.lastPathComponent): short read at \(offset)")
        }
        return [UInt8](data)
    }
}

/// Why a package could not be read. Only file names and offsets go into it, never a key.
public struct SwitchFormatError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// One file inside a PFS0 (an NSP, an NSZ) or an HFS0 (an XCI's secure partition), at its offset in the package.
struct ContainerEntry: Equatable {
    var name: String
    var offset: UInt64
    var size: UInt64
}

/// The two container formats. An NSP or NSZ is a PFS0 from its first byte; an XCI or XCZ is a cartridge image whose
/// card header (`HEAD` at 0x100) points at a root HFS0, whose `secure` partition holds the game's NCAs. The `update`
/// partition is the console firmware the cartridge carries, never the game's update, and is not read.
enum SwitchContainer {
    static func entries(of reader: PackageFileReader) throws -> [ContainerEntry] {
        let head = try reader.read(at: 0, count: Int(min(reader.size, 0x1200)))
        if head.count >= 4, head[0..<4] == [0x50, 0x46, 0x53, 0x30] {   // "PFS0"
            return try partition(reader, at: 0, entrySize: 0x18)
        }
        // A cartridge dump may carry the 0x1000-byte key area in front of the card header.
        for cardHeader in [0x100, 0x1100] where head.count >= cardHeader + 0x40 {
            guard head[cardHeader..<cardHeader + 4] == [0x48, 0x45, 0x41, 0x44] else { continue }   // "HEAD"
            let shift = UInt64(cardHeader - 0x100)
            let root = try offsetSum(shift, le64(head, cardHeader + 0x30))
            let partitions = try partition(reader, at: root, entrySize: 0x40)
            guard let secure = partitions.first(where: { $0.name == "secure" }) else {
                throw SwitchFormatError("\(reader.url.lastPathComponent): the cartridge image has no secure partition")
            }
            return try partition(reader, at: secure.offset, entrySize: 0x40)
        }
        throw SwitchFormatError("\(reader.url.lastPathComponent) is neither an NSP (PFS0) nor an XCI (HEAD at 0x100)")
    }

    /// A PFS0 (entries of 0x18 bytes) or an HFS0 (0x40): the same header, the same string table.
    static func partition(_ reader: PackageFileReader, at offset: UInt64, entrySize: Int) throws -> [ContainerEntry] {
        let header = try reader.read(at: offset, count: 16)
        let magic = entrySize == 0x18 ? "PFS0" : "HFS0"
        guard String(decoding: header[0..<4], as: UTF8.self) == magic else {
            throw SwitchFormatError("\(reader.url.lastPathComponent): no \(magic) at \(offset)")
        }
        let count = Int(le32(header, 4))
        let stringsSize = Int(le32(header, 8))
        guard count < 10_000, stringsSize < 1 << 20 else {
            throw SwitchFormatError("\(reader.url.lastPathComponent): an implausible \(magic) header at \(offset)")
        }
        let table = try reader.read(at: try offsetSum(offset, 16), count: count * entrySize + stringsSize)
        let strings = Array(table[(count * entrySize)...])
        let dataStart = try offsetSum(offset, 16, UInt64(count * entrySize + stringsSize))
        return try (0..<count).map { index in
            let base = index * entrySize
            let nameOffset = Int(le32(table, base + 16))
            guard nameOffset < strings.count else {
                throw SwitchFormatError("\(reader.url.lastPathComponent): a \(magic) name outside its string table")
            }
            let end = strings[nameOffset...].firstIndex(of: 0) ?? strings.count
            return ContainerEntry(name: String(decoding: strings[nameOffset..<end], as: UTF8.self),
                                  offset: try offsetSum(dataStart, le64(table, base)), size: le64(table, base + 8))
        }
    }

    /// The title key a ticket carries for an eShop package's NCAs (`<rights ID>.tik`), still encrypted with the
    /// title KEK. Nil for a personalised ticket, whose key is wrapped for one console only.
    static func encryptedTitleKey(ticket: [UInt8]) -> [UInt8]? {
        guard ticket.count >= 4 else { return nil }
        let signatureLength: [UInt32: Int] = [0x10000: 0x200 + 0x3C, 0x10001: 0x100 + 0x3C, 0x10002: 0x3C + 0x40,
                                              0x10003: 0x200 + 0x3C, 0x10004: 0x100 + 0x3C, 0x10005: 0x3C + 0x40]
        guard let skip = signatureLength[le32(ticket, 0)] else { return nil }
        let body = 4 + skip
        guard ticket.count >= body + 0x142, ticket[body + 0x141] == 0 else { return nil }
        return Array(ticket[(body + 0x40)..<(body + 0x50)])
    }
}

/// The sum of offsets read from a package. A sum past 2^64 is a damaged or forged file, which Swift's `+` would
/// turn into a crash of the whole launcher, in the middle of a folder scan.
func offsetSum(_ values: UInt64...) throws -> UInt64 {
    var total: UInt64 = 0
    for value in values {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { throw SwitchFormatError("an offset past the end of any file") }
        total = sum
    }
    return total
}

func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
}

func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
}

func hexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
