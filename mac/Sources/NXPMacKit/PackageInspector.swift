import Foundation

/// One title a package holds, from its content meta (`.cnmt.nca`): a merged package (base game + update + DLC in
/// one XCI or NSP) has several.
public struct PackageTitle: Equatable, Hashable, Sendable {
    public var titleID: UInt64
    public var kind: GameFolder.Kind
    /// The title version: 0 for a base game, 65536 per update step (v65536, v327680).
    public var version: UInt32
}

/// What the launcher learns about a package file, read with the user's keys.
public struct PackageContents: Equatable, Sendable {
    public var titles: [PackageTitle]
    /// From the control data's `control.nacp`: the game's name and its displayed version ("1.1.0").
    public var name: String?
    public var displayVersion: String?
    /// The control data's icon, a 256×256 JPEG.
    public var icon: Data?
    /// What could not be read (no title key, an NCZ control): the titles are known all the same.
    public var notes: [String] = []
}

/// Reads a package's content metas and control data with the keys, the way the engine's `nx_extract --contents`
/// does, without .NET or a subprocess: a few kilobytes per package, so a whole folder reads in well under a second.
public enum PackageInspector {
    public static func inspect(_ url: URL, keys: SwitchKeys) throws -> PackageContents {
        let reader = try PackageFileReader(url: url)
        let entries = try SwitchContainer.entries(of: reader)
        let tickets = Dictionary(entries.filter { $0.name.lowercased().hasSuffix(".tik") }
            .map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let ticketKey: ([UInt8]) -> [UInt8]? = { rightsID in
            guard let entry = tickets["\(hexString(rightsID)).tik"], entry.size <= 0x1000,
                  let ticket = try? reader.read(at: entry.offset, count: Int(entry.size)) else { return nil }
            return SwitchContainer.encryptedTitleKey(ticket: ticket)
        }
        let byName = Dictionary(entries.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        var contents = PackageContents(titles: [])
        var control: (version: UInt32, nca: String)?
        for entry in entries where entry.name.lowercased().hasSuffix(".cnmt.nca") {
            let nca = try NCAReader(reader: reader, entry: entry, keys: keys, ticketKey: ticketKey)
            guard let section = nca.sections.first else { continue }
            if let problem = nca.keyProblem { throw SwitchFormatError("\(entry.name): \(problem)") }
            guard let file = try nca.pfs0Files(section).first(where: { $0.name.hasSuffix(".cnmt") }) else { continue }
            let meta = try ContentMeta.parse(try nca.readFile(file, in: section))
            guard let kind = meta.kind else { continue }   // a delta or a system title: not something to build
            contents.titles.append(PackageTitle(titleID: meta.titleID, kind: kind, version: meta.version))
            // The name and icon come from the newest control data: an update's carries the current version string.
            if let id = meta.controlContentID, kind != .dlc, meta.version >= (control?.version ?? 0) {
                control = (meta.version, id)
            }
        }
        guard !contents.titles.isEmpty else {
            throw SwitchFormatError("\(url.lastPathComponent) has no content meta")
        }
        contents.titles.sort { ($0.titleID, $0.version) < ($1.titleID, $1.version) }

        if let control {
            if let entry = byName["\(control.nca).nca"] {
                do {
                    try readControl(NCAReader(reader: reader, entry: entry, keys: keys, ticketKey: ticketKey), into: &contents)
                } catch {
                    contents.notes.append("control data: \(error)")
                }
            } else if byName["\(control.nca).ncz"] != nil {
                contents.notes.append("the control data is compressed (NCZ): no name or icon")
            }
        }
        return contents
    }

    static func readControl(_ nca: NCAReader, into contents: inout PackageContents) throws {
        guard let section = nca.sections.first(where: { $0.fsType == 0 }) else { return }
        let files = try nca.romfsRootFiles(section)
        if let file = files.first(where: { $0.name == "control.nacp" }) {
            let nacp = try nca.readFile(file, in: section)
            contents.name = ControlData.name(nacp)
            contents.displayVersion = ControlData.displayVersion(nacp)
        }
        let icon = ControlData.iconOrder.lazy.compactMap { language in files.first { $0.name == "icon_\(language).dat" } }.first
            ?? files.first { $0.name.hasPrefix("icon_") && $0.name.hasSuffix(".dat") }
        if let icon, let bytes = try? nca.readFile(icon, in: section, limit: 1 << 20) {
            contents.icon = Data(bytes)
        }
    }
}

/// The `.cnmt` file of a content meta NCA.
struct ContentMeta: Equatable {
    var titleID: UInt64
    var version: UInt32
    /// 0x80 application, 0x81 patch, 0x82 add-on content, 0x83 delta.
    var type: UInt8
    /// The control NCA's content ID, in lowercase hex, when the meta lists one.
    var controlContentID: String?

    var kind: GameFolder.Kind? {
        switch type {
        case 0x80: return .base
        case 0x81: return .update
        case 0x82: return .dlc
        default: return nil
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> ContentMeta {
        guard bytes.count >= 0x20 else { throw SwitchFormatError("a content meta of \(bytes.count) bytes") }
        let extendedHeaderSize = Int(le16(bytes, 0xE))
        let contentCount = Int(le16(bytes, 0x10))
        var control: String?
        let records = 0x20 + extendedHeaderSize
        for index in 0..<contentCount {
            let record = records + index * 0x38
            guard record + 0x38 <= bytes.count else { break }
            if bytes[record + 0x36] == 3 {   // content type 3: control
                control = hexString(bytes[(record + 0x20)..<(record + 0x30)])
            }
        }
        return ContentMeta(titleID: le64(bytes, 0), version: le32(bytes, 8), type: bytes[0xC], controlContentID: control)
    }
}

/// `control.nacp`: sixteen (name, publisher) entries, one per language, then the displayed version at 0x3060.
enum ControlData {
    static let languages = ["AmericanEnglish", "BritishEnglish", "Japanese", "French", "German", "LatinAmericanSpanish",
                            "Spanish", "Italian", "Dutch", "CanadianFrench", "Portuguese", "Russian", "Korean",
                            "TraditionalChinese", "SimplifiedChinese", "BrazilianPortuguese"]
    /// English first, then the European languages a dump from this side of the world most often has.
    static let iconOrder = ["AmericanEnglish", "BritishEnglish", "French", "German", "Spanish", "Italian", "Japanese"]

    static func name(_ nacp: [UInt8]) -> String? {
        let order = [0, 1, 3, 4, 6, 7, 8, 9, 10, 15, 5, 11, 2, 12, 13, 14]
        for language in order {
            let start = language * 0x300
            guard start + 0x200 <= nacp.count else { continue }
            if let text = string(nacp[start..<(start + 0x200)]) { return text }
        }
        return nil
    }

    static func displayVersion(_ nacp: [UInt8]) -> String? {
        guard nacp.count >= 0x3070 else { return nil }
        return string(nacp[0x3060..<0x3070])
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String? {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        let text = String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// What each package file was found to be, kept while its path, size and date stay the same, so a rescan reads
/// only new or changed files. Keyed by whether keys were used too: adding prod.keys reads everything again.
public final class PackageIdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: GameFolder.Identification] = [:]

    public init() {}

    public func identify(_ url: URL, bytes: Int64, keys: SwitchKeys?) -> GameFolder.Identification {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(keys == nil ? "name" : "keys")|\(url.path)|\(bytes)|\(date?.timeIntervalSinceReferenceDate ?? 0)"
        lock.lock()
        let known = entries[key]
        lock.unlock()
        if let known { return known }
        let found = GameFolder.identify(url, bytes: bytes, keys: keys)
        lock.lock()
        entries[key] = found
        lock.unlock()
        return found
    }
}
