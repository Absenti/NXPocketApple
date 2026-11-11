import Foundation

@testable import NXPMacKit

/// Switch packages built byte by byte, encrypted with keys made up here: the format the launcher reads, with no game
/// data and no real key anywhere in the repository.
enum SwitchFixtures {
    static let headerKey = (0..<32).map { UInt8(0x10 &+ $0 &* 7) }
    static let keyAreaKey = (0..<16).map { UInt8(0xA0 &+ $0 &* 3) }
    static let titleKek = (0..<16).map { UInt8(0x55 &+ $0 &* 11) }

    static var keysText: String {
        """
        ; made up for the tests
        header_key = \(hexString(headerKey))
        key_area_key_application_00 = \(hexString(keyAreaKey))
        titlekek_00 = \(hexString(titleKek))
        some_other_key = 00
        """
    }

    static var keys: SwitchKeys { try! SwitchKeys.parse(keysText) }

    struct Meta {
        var titleID: UInt64
        var version: UInt32
        /// 0x80 application, 0x81 patch, 0x82 add-on content.
        var type: UInt8
        var control: [UInt8]?
    }

    /// An NSP (PFS0) holding one content meta NCA per `metas` entry, and, for a meta that names one, a control NCA
    /// with a name, a version string and an icon. The control NCAs use a ticket's title key, the metas the key area.
    static func nsp(_ metas: [Meta], name: String = "Test Game", displayVersion: String = "1.2.3",
                    icon: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]) -> Data {
        var files: [(String, [UInt8])] = []
        for (index, meta) in metas.enumerated() {
            let id = String(format: "%032x", 0xC0FFEE00 + index)
            if let control = meta.control {
                let rights = Array(repeating: UInt8(0), count: 8) + bigEndian(meta.titleID)
                let titleKey = (0..<16).map { UInt8(0x30 &+ $0 &+ UInt8(index)) }
                files.append(("\(hexString(control)).nca",
                              controlNCA(titleID: meta.titleID, rights: rights, titleKey: titleKey,
                                         name: name, displayVersion: displayVersion, icon: icon)))
                files.append(("\(hexString(rights)).tik", ticket(titleKey: titleKey)))
            }
            files.append(("\(id).cnmt.nca", metaNCA(meta)))
        }
        return Data(pfs0(files))
    }

    // MARK: - Containers

    static func pfs0(_ files: [(String, [UInt8])]) -> [UInt8] {
        var strings: [UInt8] = []
        var entries: [UInt8] = []
        var offset: UInt64 = 0
        for (name, data) in files {
            entries += le(offset, 8) + le(UInt64(data.count), 8) + le(UInt64(strings.count), 4) + [0, 0, 0, 0]
            strings += Array(name.utf8) + [0]
            offset += UInt64(data.count)
        }
        while strings.count % 16 != 0 { strings.append(0) }
        var out = Array("PFS0".utf8) + le(UInt64(files.count), 4) + le(UInt64(strings.count), 4) + [0, 0, 0, 0]
        out += entries + strings
        for (_, data) in files { out += data }
        return out
    }

    static func ticket(titleKey: [UInt8]) -> [UInt8] {
        var ticket = [UInt8](repeating: 0, count: 0x2C0)
        ticket.replaceSubrange(0..<4, with: le(0x10004, 4))
        ticket.replaceSubrange(0x180..<0x190, with: try! SwitchCrypto.ecb(titleKey, key: titleKek, encrypt: true))
        ticket[0x281] = 0   // a common ticket
        return ticket
    }

    // MARK: - NCAs

    static func cnmt(_ meta: Meta) -> [UInt8] {
        var bytes = le(meta.titleID, 8) + le(UInt64(meta.version), 4) + [meta.type, 0] + le(0x10, 2)
        let records = meta.control == nil ? 0 : 1
        bytes += le(UInt64(records), 2) + le(0, 2) + [UInt8](repeating: 0, count: 12)
        bytes += [UInt8](repeating: 0, count: 0x10)   // the extended header
        if let control = meta.control {
            bytes += [UInt8](repeating: 0, count: 0x20) + control + le(0x1000, 6) + [3, 0]
        }
        return bytes
    }

    static func metaNCA(_ meta: Meta) -> [UInt8] {
        let name = meta.type == 0x81 ? "Patch" : meta.type == 0x82 ? "AddOnContent" : "Application"
        let section = pfs0([("\(name)_\(String(format: "%016llx", meta.titleID)).cnmt", cnmt(meta))])
        let sectionKey = (0..<16).map { UInt8(0x77 &+ $0) }
        var fsHeader = [UInt8](repeating: 0, count: 0x200)
        fsHeader[0] = 2
        fsHeader[2] = 1   // PFS0
        fsHeader[3] = 2   // hierarchical SHA-256
        fsHeader[4] = 3   // AES-CTR
        fsHeader.replaceSubrange(0x2C..<0x30, with: le(2, 4))          // two layers
        fsHeader.replaceSubrange(0x40..<0x48, with: le(0, 8))          // the PFS0 at the start of the section
        fsHeader.replaceSubrange(0x140..<0x148, with: [1, 2, 3, 4, 5, 6, 7, 8])
        let keyArea = try! SwitchCrypto.ecb([UInt8](repeating: 0, count: 0x20) + sectionKey + [UInt8](repeating: 0, count: 0x10),
                                        key: keyAreaKey, encrypt: true)
        return nca(contentType: 1, titleID: meta.titleID, rights: nil, keyArea: keyArea, fsHeader: fsHeader,
                   section: section, sectionKey: sectionKey)
    }

    static func controlNCA(titleID: UInt64, rights: [UInt8], titleKey: [UInt8], name: String, displayVersion: String,
                           icon: [UInt8]) -> [UInt8] {
        var nacp = [UInt8](repeating: 0, count: 0x4000)
        nacp.replaceSubrange(0..<name.utf8.count, with: Array(name.utf8))
        nacp.replaceSubrange(0x3060..<(0x3060 + displayVersion.utf8.count), with: Array(displayVersion.utf8))
        let romfs = romfsImage([("control.nacp", nacp), ("icon_AmericanEnglish.dat", icon)])
        var fsHeader = [UInt8](repeating: 0, count: 0x200)
        fsHeader[0] = 2
        fsHeader[2] = 0   // RomFS
        fsHeader[3] = 3   // IVFC
        fsHeader[4] = 3   // AES-CTR
        fsHeader.replaceSubrange(0x8..<0xC, with: Array("IVFC".utf8))
        fsHeader.replaceSubrange(0x14..<0x18, with: le(7, 4))          // seven levels: the sixth data level is the RomFS
        fsHeader.replaceSubrange((0x18 + 5 * 0x18)..<(0x18 + 5 * 0x18 + 8), with: le(0x200, 8))
        fsHeader.replaceSubrange(0x140..<0x148, with: [9, 9, 9, 9, 0, 0, 0, 1])
        let section = [UInt8](repeating: 0, count: 0x200) + romfs
        return nca(contentType: 2, titleID: titleID, rights: rights, keyArea: [UInt8](repeating: 0, count: 0x40),
                   fsHeader: fsHeader, section: section, sectionKey: titleKey)
    }

    /// A RomFS of root files only: header, an empty directory table, the file table, then the data.
    static func romfsImage(_ files: [(String, [UInt8])]) -> [UInt8] {
        var table: [UInt8] = []
        var data: [UInt8] = []
        for (index, (name, bytes)) in files.enumerated() {
            let nameBytes = Array(name.utf8)
            let next = index == files.count - 1 ? UInt64(0xFFFF_FFFF) : UInt64(table.count + 0x20 + (nameBytes.count + 3) & ~3)
            table += le(0, 4) + le(next, 4) + le(UInt64(data.count), 8) + le(UInt64(bytes.count), 8)
            table += le(0xFFFF_FFFF, 4) + le(UInt64(nameBytes.count), 4) + nameBytes
            while table.count % 4 != 0 { table.append(0) }
            data += bytes
            while data.count % 16 != 0 { data.append(0) }
        }
        let fileTable: UInt64 = 0x50
        let dataOffset = (fileTable + UInt64(table.count) + 15) & ~15
        var header = le(0x50, 8)
        header += le(0x50, 8) + le(0, 8) + le(0x50, 8) + le(0, 8)          // directory hash and meta tables (empty)
        header += le(0x50, 8) + le(0, 8) + le(fileTable, 8) + le(UInt64(table.count), 8)
        header += le(dataOffset, 8)
        var image = header + table
        while UInt64(image.count) < dataOffset { image.append(0) }
        return image + data
    }

    static func nca(contentType: UInt8, titleID: UInt64, rights: [UInt8]?, keyArea: [UInt8], fsHeader: [UInt8],
                    section: [UInt8], sectionKey: [UInt8]) -> [UInt8] {
        var padded = section
        while padded.count % 0x200 != 0 { padded.append(0) }
        var header = [UInt8](repeating: 0, count: 0xC00)
        header.replaceSubrange(0x200..<0x204, with: Array("NCA3".utf8))
        header[0x205] = contentType
        header.replaceSubrange(0x208..<0x210, with: le(UInt64(0xC00 + padded.count), 8))
        header.replaceSubrange(0x210..<0x218, with: le(titleID, 8))
        if let rights { header.replaceSubrange(0x230..<0x240, with: rights) }
        header.replaceSubrange(0x240..<0x244, with: le(6, 4))
        header.replaceSubrange(0x244..<0x248, with: le(UInt64(6 + padded.count / 0x200), 4))
        header.replaceSubrange(0x300..<0x340, with: keyArea)
        header.replaceSubrange(0x400..<0x600, with: fsHeader)
        var counter = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 { counter[index] = fsHeader[0x147 - index] }
        counter.replaceSubrange(8..<16, with: bigEndian(UInt64(0xC00 >> 4)))
        let encrypted = try! SwitchCrypto.ctr(padded, key: sectionKey, counter: counter)
        return try! SwitchCrypto.xtsEncrypt(header, key: headerKey, firstSector: 0) + encrypted
    }

    // MARK: - Bytes

    static func le(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }

    static func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * UInt64(7 - $0))) & 0xFF) }
    }
}
