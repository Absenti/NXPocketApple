import Foundation

/// A minimal Mach-O reader: enough of the load commands to decide whether a framework the Mac app sent is
/// safe to run on the phone. No dependency, no reliance on `otool`.
public struct MachOFile {
    public static let magic64: UInt32 = 0xfeed_facf
    public static let magic32: UInt32 = 0xfeed_face
    public static let fatMagic: UInt32 = 0xcafe_babe
    public static let fatMagic64: UInt32 = 0xcafe_babf

    public static let cpuTypeARM64: Int32 = 0x0100_000C
    public static let cpuSubtypeARM64E: Int32 = 2
    public static let fileTypeDylib: UInt32 = 6

    public struct Header: Equatable, Sendable {
        public var magic: UInt32
        public var cpuType: Int32
        public var cpuSubtype: Int32
        public var fileType: UInt32
        public var commandCount: UInt32
        public var flags: UInt32
        public var is64: Bool
        public var isARM64: Bool { cpuType == MachOFile.cpuTypeARM64 }
        public var isDylib: Bool { fileType == MachOFile.fileTypeDylib }
    }

    public struct Section: Equatable, Sendable {
        public var segment: String
        public var name: String
        public var address: UInt64
        public var size: UInt64
        public var offset: UInt32
        public var flags: UInt32
    }

    public struct Segment: Equatable, Sendable {
        public var name: String
        public var vmAddress: UInt64
        public var vmSize: UInt64
        public var fileOffset: UInt64
        public var fileSize: UInt64
        public var sections: [Section]
    }

    public struct Dependency: Equatable, Sendable {
        public enum Kind: String, Sendable { case load, weak, reexport, lazy, upward, identifier }
        public var kind: Kind
        public var name: String
    }

    public struct BuildVersion: Equatable, Sendable {
        public static let platformIOS: UInt32 = 2
        public static let platformMacOS: UInt32 = 1
        public static let platformIOSTargetEnvironmentSimulator: UInt32 = 7

        public var platform: UInt32
        public var minimumOS: OSVersion
        /// The SDK the code was linked against, decoded from the encoded version word.
        public var sdkVersion: OSVersion
    }

    public struct CodeSignatureLocation: Equatable, Sendable {
        public var offset: UInt64
        public var size: UInt64
    }

    public var header: Header
    public var dependencies: [Dependency]
    public var buildVersion: BuildVersion?
    /// `LC_VERSION_MIN_IPHONEOS`, the older way to state a deployment target.
    public var legacyMinimumOS: OSVersion?
    public var codeSignature: CodeSignatureLocation?
    public var segments: [Segment]
    public var rpaths: [String]
    public var uuid: UUID?
    /// The whole file, kept so the signature reader does not read it twice.
    public let data: Data

    /// The deployment target, newest of the two ways a Mach-O can state one.
    public var minimumOS: OSVersion? {
        switch (buildVersion?.minimumOS, legacyMinimumOS) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    public static func isMachO(magic: UInt32) -> Bool {
        magic == magic64 || magic == magic32 || magic == fatMagic || magic == fatMagic64
    }

    /// Reads the first word of `data` as a Mach-O magic, whichever byte order it is written in.
    public static func magic(of data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    }

    public static func isFat(_ data: Data) -> Bool {
        guard let m = magic(of: data) else { return false }
        return m == fatMagic || m == fatMagic64 || m.byteSwapped == fatMagic || m.byteSwapped == fatMagic64
    }

    public static func parse(contentsOf url: URL) throws -> MachOFile {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw NXPocketError(.packageMissing, "cannot read the executable", path: url.path)
        }
        return try parse(data, path: url.path)
    }

    public static func parse(_ data: Data, path: String = "") throws -> MachOFile {
        guard let magic = magic(of: data) else {
            throw NXPocketError(.notAMachO, "file is too short to be a Mach-O", path: path)
        }
        guard magic != fatMagic, magic != fatMagic64, magic.byteSwapped != fatMagic, magic.byteSwapped != fatMagic64 else {
            throw NXPocketError(.fatBinary, "fat (universal) binaries are refused", path: path)
        }
        let is64 = magic == magic64
        guard is64 || magic == magic32 else {
            throw NXPocketError(.notAMachO, String(format: "unknown Mach-O magic %#x", magic), path: path)
        }
        let reader = Reader(data)
        let headerSize = is64 ? 32 : 28
        guard data.count >= headerSize else {
            throw NXPocketError(.notAMachO, "truncated Mach-O header", path: path)
        }
        let header = Header(magic: magic,
                            cpuType: Int32(bitPattern: reader.u32(4)),
                            cpuSubtype: Int32(bitPattern: reader.u32(8)),
                            fileType: reader.u32(12),
                            commandCount: reader.u32(16),
                            flags: reader.u32(is64 ? 24 : 20),
                            is64: is64)

        var dependencies: [Dependency] = []
        var buildVersion: BuildVersion?
        var legacyMinimumOS: OSVersion?
        var codeSignature: CodeSignatureLocation?
        var segments: [Segment] = []
        var rpaths: [String] = []
        var uuid: UUID?

        var offset = headerSize
        for _ in 0..<header.commandCount {
            guard offset + 8 <= data.count else { break }
            let cmd = reader.u32(offset)
            let size = Int(reader.u32(offset + 4))
            guard size >= 8, offset + size <= data.count else { break }
            defer { offset += size }

            switch cmd {
            case 0x1D: // LC_CODE_SIGNATURE
                codeSignature = CodeSignatureLocation(offset: UInt64(reader.u32(offset + 8)), size: UInt64(reader.u32(offset + 12)))
            case 0x19: // LC_SEGMENT_64
                segments.append(segment(from: reader, offset: offset, size: size))
            case 0x32: // LC_BUILD_VERSION
                let encoded = reader.u32(offset + 12)
                buildVersion = BuildVersion(platform: reader.u32(offset + 8),
                                            minimumOS: Self.decodeVersion(encoded),
                                            sdkVersion: Self.decodeVersion(reader.u32(offset + 16)))
            case 0x25: // LC_VERSION_MIN_IPHONEOS
                legacyMinimumOS = Self.decodeVersion(reader.u32(offset + 8))
            case 0x1C | 0x8000_001C: // LC_RPATH
                if let name = Self.string(reader, at: offset, size) { rpaths.append(name) }
            case 0x1B: // LC_UUID
                if size >= 24 {
                    let bytes = (0..<16).map { reader.u8(offset + 8 + $0) }
                    uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                }
            case 0x0C: // LC_LOAD_DYLIB
                if let name = Self.string(reader, at: offset, size) { dependencies.append(Dependency(kind: .load, name: name)) }
            case 0x8000_0018: // LC_LOAD_WEAK_DYLIB
                if let name = Self.string(reader, at: offset, size) { dependencies.append(Dependency(kind: .weak, name: name)) }
            case 0x8000_001F: // LC_REEXPORT_DYLIB
                if let name = Self.string(reader, at: offset, size) { dependencies.append(Dependency(kind: .reexport, name: name)) }
            // Two older forms of a dependency: each still names a library dyld opens, so each goes through the policy.
            case 0x20: // LC_LAZY_LOAD_DYLIB
                if let name = Self.string(reader, at: offset, size) { dependencies.append(Dependency(kind: .lazy, name: name)) }
            case 0x8000_0023: // LC_LOAD_UPWARD_DYLIB
                if let name = Self.string(reader, at: offset, size) { dependencies.append(Dependency(kind: .upward, name: name)) }
            case 0x0D: // LC_ID_DYLIB
                if let name = Self.string(reader, at: offset, size) { dependencies.append(Dependency(kind: .identifier, name: name)) }
            default:
                break
            }
        }

        return MachOFile(header: header, dependencies: dependencies, buildVersion: buildVersion,
                         legacyMinimumOS: legacyMinimumOS, codeSignature: codeSignature,
                         segments: segments, rpaths: rpaths, uuid: uuid, data: data)
    }

    /// `X.Y.Z` packed as `(X << 16) | (Y << 8) | Z`.
    static func decodeVersion(_ word: UInt32) -> OSVersion {
        OSVersion(major: Int((word >> 16) & 0xFFFF), minor: Int((word >> 8) & 0xFF), patch: Int(word & 0xFF))
    }

    static func encodeVersion(_ version: OSVersion) -> UInt32 {
        UInt32(version.major & 0xFFFF) << 16 | UInt32(version.minor & 0xFF) << 8 | UInt32(version.patch & 0xFF)
    }

    /// The name a `lc_str` command carries: the offset is relative to the start of the command, not to the field.
    private static func string(_ reader: Reader, at command: Int, _ commandSize: Int) -> String? {
        guard command + 12 <= reader.count else { return nil }
        let stringOffset = Int(reader.u32(command + 8))
        guard stringOffset > 0, stringOffset < commandSize else { return nil }
        return reader.cString(at: command + stringOffset, limitedTo: commandSize - stringOffset)
    }

    private static func segment(from reader: Reader, offset: Int, size: Int) -> Segment {
        let name = reader.fixedString(at: offset + 8, length: 16)
        var sections: [Section] = []
        let sectionStart = offset + 72
        // The count comes from the file: only the sections that fit in the command are read, so a forged count of
        // four billion costs nothing.
        let sectionCount = min(Int(reader.u32(offset + 64)), max(0, (offset + size - sectionStart) / 80))
        for i in 0..<sectionCount {
            let base = sectionStart + i * 80
            sections.append(Section(segment: reader.fixedString(at: base + 16, length: 16),
                                    name: reader.fixedString(at: base, length: 16),
                                    address: reader.u64(base + 32),
                                    size: reader.u64(base + 40),
                                    offset: reader.u32(base + 48),
                                    flags: reader.u32(base + 64)))
        }
        return Segment(name: name,
                       vmAddress: reader.u64(offset + 24),
                       vmSize: reader.u64(offset + 32),
                       fileOffset: reader.u64(offset + 40),
                       fileSize: reader.u64(offset + 48),
                       sections: sections)
    }

    /// A 16K-aligned section with both read and execute permissions, the shape the engine's code pages have.
    public func section(segment wantedSegment: String, name wantedName: String) -> Section? {
        segments.first { $0.name == wantedSegment }?.sections.first { $0.name == wantedName }
    }
}

/// Bounds-checked little-endian reads; a truncated file reads as zero rather than trapping.
struct Reader {
    let data: Data

    init(_ data: Data) { self.data = data }
    var count: Int { data.count }

    func u8(_ offset: Int) -> UInt8 {
        guard offset >= 0, offset < data.count else { return 0 }
        return data[data.startIndex + offset]
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    func be32(_ offset: Int) -> UInt32 { u32(offset).byteSwapped }

    func u64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    }

    func fixedString(at offset: Int, length: Int) -> String {
        let bytes = (0..<length).map { u8(offset + $0) }
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(bytes: bytes[0..<end], encoding: .utf8) ?? ""
    }

    func cString(at offset: Int, limitedTo limit: Int) -> String? {
        guard offset >= 0, offset < data.count, limit > 0 else { return nil }
        var bytes: [UInt8] = []
        var index = offset
        while index < data.count, index - offset < limit {
            let byte = u8(index)
            if byte == 0 { break }
            bytes.append(byte)
            index += 1
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
