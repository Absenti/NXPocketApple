import Foundation

/// A Switch title ID: 16 hex digits, e.g. `0100152000022000`.
public struct TitleID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Accepts lower or upper case. The base application and its updates/add-ons differ only in the low bits.
    public init?(_ text: String) {
        guard text.count == 16, let value = UInt64(text, radix: 16) else { return nil }
        self.rawValue = value
    }

    public var description: String { String(format: "%016llX", rawValue) }

    /// The base application ID: updates (0x800) and add-ons (0x1000+) share the base's high bits.
    public var baseApplication: TitleID { TitleID(rawValue: rawValue & ~UInt64(0xFFF)) }

    /// The content-type field of a title ID is its low 12 bits: `0x000` for a game, `0x800` for its update.
    public var kind: Kind {
        switch rawValue & 0xFFF {
        case 0x000: return .application
        case 0x800: return .update
        default: return .other
        }
    }

    public enum Kind: String, Sendable { case application, update, other }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// True for `0100XXXXXXXXXXXX`, the shape every game's own ID has.
    public static func isGame(_ text: String) -> Bool {
        guard let id = TitleID(text) else { return false }
        return id.kind == .application && text.uppercased().hasPrefix("0100")
    }
}
