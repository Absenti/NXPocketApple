import Foundation
import NXPocketKit

/// The player's arrangement of the touch controls: for each layout, how far each moved control sits from its built-in place.
/// It reaches every game as one `DM_TOUCH_LAYOUT` value, which the engine reads in `DmPadGeometry.h` (`dm_pad_layout_parse`,
/// "The player's arrangement"): `1`, then per layout `;`, its name and `/control:dx,dy` per moved control, for example
/// `1;2d/face:0,-2/stick:1,-1;3d/a:-1,0`. A step is a quarter of a face key's width at the player's size, y grows downward.
///
/// The engine ignores a value it cannot read whole, so this type only ever writes the form: offsets are clamped to the
/// engine's ±64 and the longest possible value (four layouts, every control moved) stays under its 1024 characters.
public struct TouchLayout: Equatable, Sendable {
    /// The layouts with an arrangement of their own, by the engine's names: 2D and 3D over the picture, and both again below
    /// the picture (an iPad held upright, a foldable). The iPhone only ever shows the first two; the others are kept as read.
    public enum Kind: String, CaseIterable, Sendable {
        case twoD = "2d", threeD = "3d", twoDSplit = "2s", threeDSplit = "3s"
        /// The 3D layout: the D-pad, L3 and R3 are drawn too.
        public var full: Bool { self == .threeD || self == .threeDSplit }
    }

    /// The controls that move, in the engine's order, which is the order it places them in (`dm_pad_control_names`). `face`
    /// is the whole A B X Y diamond, `a b x y` one key of it, from where the diamond is. The menu button never moves.
    public enum Control: String, CaseIterable, Sendable {
        case face, a, b, x, y, stick, dpad, zl, l, zr, r, l3, r3, minus, plus

        /// Drawn in this layout: the D-pad, L3 and R3 only in 3D (`dm_pad_control_drawn`).
        public func drawn(full: Bool) -> Bool { full || ![.dpad, .l3, .r3].contains(self) }
        public var isFaceKey: Bool { [.a, .b, .x, .y].contains(self) }
    }

    public struct Offset: Equatable, Hashable, Sendable {
        public var dx: Int
        public var dy: Int
        public init(dx: Int = 0, dy: Int = 0) { self.dx = dx; self.dy = dy }
        public static let zero = Offset()
        public var isZero: Bool { dx == 0 && dy == 0 }
    }

    /// `DM_PAD_STEP_MAX` and `DM_PAD_LAYOUT_MAX`.
    public static let maxStep = 64
    public static let maxLength = 1024

    private var offsets: [Kind: [Control: Offset]] = [:]

    public init() {}

    public subscript(kind: Kind, control: Control) -> Offset {
        get { offsets[kind]?[control] ?? .zero }
        set {
            let clamped = Offset(dx: Swift.min(Self.maxStep, Swift.max(-Self.maxStep, newValue.dx)),
                                 dy: Swift.min(Self.maxStep, Swift.max(-Self.maxStep, newValue.dy)))
            var moved = offsets[kind] ?? [:]
            moved[control] = clamped.isZero ? nil : clamped
            offsets[kind] = moved.isEmpty ? nil : moved
        }
    }

    public var isEmpty: Bool { offsets.isEmpty }
    public func isEmpty(_ kind: Kind) -> Bool { offsets[kind] == nil }
    public mutating func reset(_ kind: Kind) { offsets[kind] = nil }

    /// The value for `DM_TOUCH_LAYOUT`, empty when nothing moved: the built-in layout, and nothing to pass.
    public var encoded: String {
        guard !offsets.isEmpty else { return "" }
        var out = "1"
        for kind in Kind.allCases {
            guard let moved = offsets[kind] else { continue }
            out += ";" + kind.rawValue
            for control in Control.allCases {
                if let o = moved[control] { out += "/\(control.rawValue):\(o.dx),\(o.dy)" }
            }
        }
        return out
    }

    /// Reads a value the way `dm_pad_layout_parse` does: an unknown layout or control is skipped (a newer shell wrote it), and
    /// anything else that is not the form, or is longer than the engine reads, gives nil, as the engine then ignores it whole.
    /// Empty is the built-in layout.
    public init?(encoded value: String) {
        self.init()
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return }
        guard bytes.count <= Self.maxLength, bytes[0] == UInt8(ascii: "1"),
              bytes.count == 1 || bytes[1] == UInt8(ascii: ";") else { return nil }
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        var i = 1
        func step() -> Int? {
            var sign = 1, v = 0, digits = 0
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { sign = -1; i += 1 }
            while i < bytes.count, isDigit(bytes[i]) {
                digits += 1
                if digits > 3 { return nil }
                v = v * 10 + Int(bytes[i] - UInt8(ascii: "0"))
                i += 1
            }
            return digits > 0 && v <= Self.maxStep ? sign * v : nil
        }
        while i < bytes.count, bytes[i] == UInt8(ascii: ";") {
            i += 1
            let nameStart = i
            while i < bytes.count, bytes[i] != UInt8(ascii: "/"), bytes[i] != UInt8(ascii: ";") { i += 1 }
            let kind = Kind(rawValue: String(decoding: bytes[nameStart..<i], as: UTF8.self))
            while i < bytes.count, bytes[i] == UInt8(ascii: "/") {
                i += 1
                let start = i
                while i < bytes.count, (bytes[i] >= UInt8(ascii: "a") && bytes[i] <= UInt8(ascii: "z")) || isDigit(bytes[i]) { i += 1 }
                guard i > start, i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                let name = String(decoding: bytes[start..<i], as: UTF8.self)
                i += 1
                guard let dx = step(), i < bytes.count, bytes[i] == UInt8(ascii: ",") else { return nil }
                i += 1
                guard let dy = step() else { return nil }
                if let kind, let control = Control(rawValue: name) { self[kind, control] = Offset(dx: dx, dy: dy) }
            }
            if i < bytes.count, bytes[i] != UInt8(ascii: ";") { return nil }
        }
        if i < bytes.count { return nil }
    }
}

/// The touch controls' options, one set for every game: the size (`DM_TOUCH_SIZE`), where the left stick sits
/// (`DM_TOUCH_STICK`), both read in `DmGamepad.m`, and the arrangement (`DM_TOUCH_LAYOUT`). Kept in
/// `Documents/settings/touch.json`, which an update of the app in place keeps.
public struct TouchControls: Equatable, Sendable {
    /// `dm_pad_size_scale`: 0.8, 1 (the built-in size) and 1.2.
    public enum Size: String, CaseIterable, Sendable {
        case small, medium, large
        public var scale: CGFloat { self == .small ? 0.8 : self == .large ? 1.2 : 1 }
    }

    /// `dm_pad_stick_place`: the left stick in the corner, lifted toward the shoulders, or moved inward with the D-pad.
    public enum Stick: String, CaseIterable, Sendable {
        case corner, higher, inward
    }

    public var size: Size = .medium
    public var stick: Stick = .corner
    public var layout = TouchLayout()

    public init(size: Size = .medium, stick: Stick = .corner, layout: TouchLayout = TouchLayout()) {
        self.size = size
        self.stick = stick
        self.layout = layout
    }

    /// What a game's engine reads. The size and the stick are always passed, so the log says which ones a game started
    /// with; the arrangement only when something moved. `hint` is the 3D layout's right-stick hint in the player's language
    /// (`DM_TOUCH_HINT`), which the engine otherwise shows in English.
    public func environment(hint: String?) -> [String: String] {
        var environment = ["DM_TOUCH_SIZE": size.rawValue, "DM_TOUCH_STICK": stick.rawValue]
        if !layout.isEmpty { environment["DM_TOUCH_LAYOUT"] = layout.encoded }
        if let hint, !hint.isEmpty { environment["DM_TOUCH_HINT"] = hint }
        return environment
    }

    // MARK: - Storage

    public static func url(documents: URL) -> URL {
        SettingsFolder.url(documents: documents).appendingPathComponent("touch.json")
    }

    /// The saved options. A missing or damaged file, an unknown size or stick place, and an arrangement the engine would
    /// ignore all read as the built-in choice, so a bad file never reaches a game.
    public static func load(documents: URL, fileManager: FileManager = .default) -> TouchControls {
        guard let data = BoundedRead.dataIfPresent(at: url(documents: documents), fileManager: fileManager),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return TouchControls() }
        var controls = TouchControls()
        if let size = (object["size"] as? String).flatMap(Size.init(rawValue:)) { controls.size = size }
        if let stick = (object["stick"] as? String).flatMap(Stick.init(rawValue:)) { controls.stick = stick }
        if let layout = (object["layout"] as? String).flatMap(TouchLayout.init(encoded:)) { controls.layout = layout }
        return controls
    }

    public func save(documents: URL, fileManager: FileManager = .default) throws {
        let object: [String: Any] = ["schema": 1, "size": size.rawValue, "stick": stick.rawValue, "layout": layout.encoded]
        try SettingsFolder.write(object, to: Self.url(documents: documents), fileManager: fileManager)
    }
}

/// `Documents/settings/`: the player's choices, outside the game folders. An update of a game replaces its folder whole and
/// keeps only its saves, so a choice kept in there would be lost with every update.
public enum SettingsFolder {
    public static func url(documents: URL) -> URL {
        documents.appendingPathComponent("settings", isDirectory: true)
    }

    /// Writes atomically: a crash mid-write leaves the previous choices, never half a file.
    static func write(_ object: [String: Any], to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
