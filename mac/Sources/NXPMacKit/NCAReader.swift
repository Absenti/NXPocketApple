import Foundation

/// One NCA inside a package: its header, decrypted with `header_key`, and reads of its sections, decrypted with the
/// key its key area (or its ticket) gives. Only what identifying a package needs: the content meta's PFS0 and the
/// control data's RomFS. Patched (BKTR) and compressed (NCZ) sections are never read.
struct NCAReader {
    enum ContentType: UInt8 {
        case program = 0, meta, control, manual, data, publicData
    }

    struct Section {
        var index: Int
        /// Byte offsets in the NCA.
        var start: UInt64
        var end: UInt64
        /// 0 RomFS, 1 PFS0.
        var fsType: UInt8
        /// 2 hierarchical SHA-256 (a PFS0), 3 hierarchical integrity (IVFC, a RomFS).
        var hashType: UInt8
        /// 1 none, 3 AES-CTR, 5 AES-CTR without the hash layers' encryption; anything else is not read here.
        var encryptionType: UInt8
        /// The counter's upper half, as the FS header stores it (reversed into the counter block).
        var counterUpper: [UInt8]
        var hashData: [UInt8]
    }

    let reader: PackageFileReader
    let base: UInt64
    let size: UInt64
    let contentType: ContentType?
    let titleID: UInt64
    let rightsID: [UInt8]
    let masterKeyRevision: Int
    let sections: [Section]
    private let sectionKey: [UInt8]?

    static let headerSize = 0xC00

    /// `ticketKey` gives the encrypted title key of a rights ID, for an NCA that has one.
    init(reader: PackageFileReader, entry: ContainerEntry, keys: SwitchKeys,
         ticketKey: (_ rightsID: [UInt8]) -> [UInt8]?) throws {
        self.reader = reader
        base = entry.offset
        size = entry.size
        guard size >= UInt64(Self.headerSize) else { throw SwitchFormatError("\(entry.name) is too short for an NCA") }
        let encrypted = try reader.read(at: base, count: Self.headerSize)
        let header = try SwitchCrypto.xtsDecrypt(encrypted, key: keys.headerKey, firstSector: 0)
        let magic = String(decoding: header[0x200..<0x204], as: UTF8.self)
        guard magic == "NCA3" else {
            // NCA2 numbers each FS header's sectors from zero, and NCA0 is older still; neither is in a game sold
            // since 2017, and a wrong header_key looks exactly like this.
            throw SwitchFormatError(magic.hasPrefix("NCA")
                ? "\(entry.name) is an \(magic), which this launcher does not read"
                : "\(entry.name) does not decrypt with the header_key of prod.keys")
        }
        contentType = ContentType(rawValue: header[0x205])
        titleID = le64(header, 0x210)
        rightsID = Array(header[0x230..<0x240])
        let generation = Int(max(header[0x206], header[0x220]))
        masterKeyRevision = generation > 0 ? generation - 1 : 0
        let keyAreaIndex = header[0x207]

        var sections: [Section] = []
        for index in 0..<4 {
            let entryOffset = 0x240 + index * 0x10
            let start = UInt64(le32(header, entryOffset)) * 0x200
            let end = UInt64(le32(header, entryOffset + 4)) * 0x200
            guard end > start else { continue }
            let fs = Array(header[(0x400 + index * 0x200)..<(0x600 + index * 0x200)])
            sections.append(Section(index: index, start: start, end: end, fsType: fs[2], hashType: fs[3],
                                    encryptionType: fs[4], counterUpper: Array(fs[0x140..<0x148]),
                                    hashData: Array(fs[0x8..<0x100])))
        }
        self.sections = sections

        if rightsID.contains(where: { $0 != 0 }) {
            // An eShop package: the section key is the title key, from the ticket, under the title KEK.
            if let wrapped = ticketKey(rightsID), let kek = keys.titleKek[masterKeyRevision] {
                sectionKey = try SwitchCrypto.ecb(wrapped, key: kek, encrypt: false)
            } else {
                sectionKey = nil
            }
        } else if keyAreaIndex == 0, let keyAreaKey = keys.keyAreaApplication[masterKeyRevision] {
            // Standard crypto: the key area's third key is the AES-CTR key.
            let keyArea = try SwitchCrypto.ecb(Array(header[0x300..<0x340]), key: keyAreaKey, encrypt: false)
            sectionKey = Array(keyArea[0x20..<0x30])
        } else {
            sectionKey = nil
        }
    }

    /// Why a section cannot be read, or nil.
    var keyProblem: String? {
        guard sectionKey == nil else { return nil }
        return rightsID.contains(where: { $0 != 0 })
            ? "no title key for it (a personalised ticket, or prod.keys lacks titlekek_\(String(format: "%02x", masterKeyRevision)))"
            : "prod.keys lacks key_area_key_application_\(String(format: "%02x", masterKeyRevision))"
    }

    /// `count` bytes at `offset` in a section, decrypted.
    func read(_ section: Section, at offset: UInt64, count: Int) throws -> [UInt8] {
        let absolute = try offsetSum(section.start, offset)
        let end = try offsetSum(absolute, UInt64(max(count, 0)))
        guard count >= 0, end <= section.end, end <= size else {
            throw SwitchFormatError("a read past the end of NCA section \(section.index)")
        }
        switch section.encryptionType {
        case 1:
            return try reader.read(at: try offsetSum(base, absolute), count: count)
        case 3, 5:
            guard let sectionKey else { throw SwitchFormatError(keyProblem ?? "no section key") }
            let aligned = absolute & ~UInt64(0xF)
            let lead = Int(absolute - aligned)
            let length = (lead + count + 15) & ~15
            let cipher = try reader.read(at: try offsetSum(base, aligned), count: min(length, Int(size - aligned)))
            var counter = [UInt8](repeating: 0, count: 16)
            for index in 0..<8 { counter[index] = section.counterUpper[7 - index] }
            var block = aligned >> 4
            for index in stride(from: 15, through: 8, by: -1) {
                counter[index] = UInt8(block & 0xFF)
                block >>= 8
            }
            let plain = try SwitchCrypto.ctr(cipher, key: sectionKey, counter: counter)
            return Array(plain[lead..<(lead + count)])
        default:
            throw SwitchFormatError("NCA section \(section.index) uses encryption type \(section.encryptionType)")
        }
    }

    // MARK: - File systems

    /// The files of a PFS0 section (the content meta's), with offsets in the section.
    func pfs0Files(_ section: Section) throws -> [ContainerEntry] {
        guard section.fsType == 1, section.hashType == 2 else {
            throw SwitchFormatError("NCA section \(section.index) is not a PFS0")
        }
        let layers = Int(le32(section.hashData, 0x24))
        guard (1...5).contains(layers) else { throw SwitchFormatError("NCA section \(section.index): \(layers) hash layers") }
        let start = le64(section.hashData, 0x28 + (layers - 1) * 0x10)
        let header = try read(section, at: start, count: 16)
        guard String(decoding: header[0..<4], as: UTF8.self) == "PFS0" else {
            throw SwitchFormatError("NCA section \(section.index) holds no PFS0")
        }
        let count = Int(le32(header, 4))
        let stringsSize = Int(le32(header, 8))
        guard count < 1000, stringsSize < 1 << 16 else { throw SwitchFormatError("an implausible PFS0 in an NCA") }
        let table = try read(section, at: try offsetSum(start, 16), count: count * 0x18 + stringsSize)
        let strings = Array(table[(count * 0x18)...])
        let dataStart = try offsetSum(start, 16, UInt64(count * 0x18 + stringsSize))
        return try (0..<count).compactMap { index in
            let nameOffset = Int(le32(table, index * 0x18 + 16))
            guard nameOffset < strings.count else { return nil }
            let end = strings[nameOffset...].firstIndex(of: 0) ?? strings.count
            return ContainerEntry(name: String(decoding: strings[nameOffset..<end], as: UTF8.self),
                                  offset: try offsetSum(dataStart, le64(table, index * 0x18)), size: le64(table, index * 0x18 + 8))
        }
    }

    /// The files at the root of a RomFS section (the control data's: `control.nacp`, `icon_<language>.dat`), with
    /// offsets in the section. Subfolders are not walked: the control data has none.
    func romfsRootFiles(_ section: Section) throws -> [ContainerEntry] {
        guard section.fsType == 0, section.hashType == 3 else {
            throw SwitchFormatError("NCA section \(section.index) is not a RomFS")
        }
        guard String(decoding: section.hashData[0..<4], as: UTF8.self) == "IVFC" else {
            throw SwitchFormatError("NCA section \(section.index) has no IVFC header")
        }
        let levels = Int(le32(section.hashData, 0xC))
        guard (2...7).contains(levels) else { throw SwitchFormatError("an IVFC of \(levels) levels") }
        // The last level of the hash tree is the RomFS itself.
        let romfs = le64(section.hashData, 0x10 + (levels - 2) * 0x18)
        let header = try read(section, at: romfs, count: 0x50)
        let fileTable = le64(header, 0x38)
        let fileTableSize = le64(header, 0x40)
        let data = le64(header, 0x48)
        guard fileTableSize < 1 << 20 else { throw SwitchFormatError("an implausible RomFS file table") }
        let table = try read(section, at: try offsetSum(romfs, fileTable), count: Int(fileTableSize))
        var files: [ContainerEntry] = []
        var position = 0
        while position + 0x20 <= table.count {
            let parent = le32(table, position)
            let offset = le64(table, position + 0x8)
            let length = le64(table, position + 0x10)
            let nameSize = Int(le32(table, position + 0x1C))
            guard position + 0x20 + nameSize <= table.count else { break }
            if parent == 0 {
                let name = String(decoding: table[(position + 0x20)..<(position + 0x20 + nameSize)], as: UTF8.self)
                files.append(ContainerEntry(name: name, offset: try offsetSum(romfs, data, offset), size: length))
            }
            position += 0x20 + ((nameSize + 3) & ~3)
        }
        return files
    }

    func readFile(_ file: ContainerEntry, in section: Section, limit: Int = 4 << 20) throws -> [UInt8] {
        guard file.size <= UInt64(limit) else { throw SwitchFormatError("\(file.name) is larger than expected") }
        return try read(section, at: file.offset, count: Int(file.size))
    }
}
