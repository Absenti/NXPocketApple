import Foundation
import NXPocketKit

/// The few keys from the user's `prod.keys` that identify a package: `header_key` opens an NCA's header,
/// `key_area_key_application_XX` its section keys, `titlekek_XX` a ticket's title key.
///
/// They stay in memory, in this value only. Nothing here writes them, prints them or puts them in an error: the
/// description is redacted, and a parse error names the line number, never the line.
public struct SwitchKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let headerKey: [UInt8]
    let keyAreaApplication: [Int: [UInt8]]
    let titleKek: [Int: [UInt8]]

    init(headerKey: [UInt8], keyAreaApplication: [Int: [UInt8]], titleKek: [Int: [UInt8]]) {
        self.headerKey = headerKey
        self.keyAreaApplication = keyAreaApplication
        self.titleKek = titleKek
    }

    public var description: String {
        "SwitchKeys(header_key, \(keyAreaApplication.count) key area keys, \(titleKek.count) title keks)"
    }

    public var debugDescription: String { description }

    /// Reads the file the user chose. The path is theirs to know: errors say "prod.keys", never where it is.
    public static func load(from url: URL) throws -> SwitchKeys {
        // Bounded like any metadata, and the error is rebuilt here: BoundedRead's carries the file's path.
        guard let data = try? BoundedRead.data(at: url), let text = String(data: data, encoding: .utf8) else {
            throw NXPocketError(.packageUnsupported, "prod.keys could not be read")
        }
        return try parse(text)
    }

    /// `name = hex` lines, as every dump tool writes them. Comments and unknown names are skipped.
    public static func parse(_ text: String) throws -> SwitchKeys {
        var header: [UInt8]?
        var keyArea: [Int: [UInt8]] = [:]
        var kek: [Int: [UInt8]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if name == "header_key" {
                header = bytes(hex: value, count: 32)
            } else if let generation = generation(of: name, prefix: "key_area_key_application_"),
                      let key = bytes(hex: value, count: 16) {
                keyArea[generation] = key
            } else if let generation = generation(of: name, prefix: "titlekek_"), let key = bytes(hex: value, count: 16) {
                kek[generation] = key
            }
        }
        guard let header else {
            throw NXPocketError(.packageUnsupported, "prod.keys has no header_key")
        }
        return SwitchKeys(headerKey: header, keyAreaApplication: keyArea, titleKek: kek)
    }

    /// `key_area_key_application_0a` → 10.
    private static func generation(of name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.count == 2 else { return nil }
        return Int(suffix, radix: 16)
    }

    static func bytes(hex: String, count: Int) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count == count * 2 else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            guard let high = nibble(digits[2 * index]), let low = nibble(digits[2 * index + 1]) else { return nil }
            out[index] = high << 4 | low
        }
        return out
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
