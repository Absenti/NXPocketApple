import Foundation
import NXPocketKit

/// One row of a game's `dm/launcher.json`, with the fields and rules of the engine's own `Setting`
/// (`dm/ios/Sources/LauncherSettings.swift`), so a value kept here means what the engine's launcher means by it. Each row
/// sets one environment variable the engine reads when the game starts.
public struct LauncherSetting: Decodable, Equatable, Sendable, Identifiable {
    public var env: String
    public var kind: String
    public var label: String
    public var note: String
    public var def: String
    public var section: String?
    /// `<VAR>=<value>`: a sub-setting, shown only while that setting has that value.
    public var needs: String?
    public var options: [[String]]?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var on: String?
    public var off: String?

    public var id: String { env }
    public var sectionTitle: String { section ?? "Game" }
    public var onValue: String { on ?? "1" }
    public var offValue: String { off ?? "0" }

    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, needs, options, min, max, step, on, off }

    public init(env: String, kind: String, label: String, note: String = "", def: String, section: String? = nil,
                needs: String? = nil, options: [[String]]? = nil, min: Double? = nil, max: Double? = nil,
                step: Double? = nil, on: String? = nil, off: String? = nil) {
        self.env = env; self.kind = kind; self.label = label; self.note = note; self.def = def; self.section = section
        self.needs = needs; self.options = options; self.min = min; self.max = max; self.step = step; self.on = on; self.off = off
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        env = try c.decode(String.self, forKey: .env)
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        def = try c.decode(String.self, forKey: .def)
        section = try c.decodeIfPresent(String.self, forKey: .section)
        needs = try c.decodeIfPresent(String.self, forKey: .needs)
        options = try c.decodeIfPresent([[String]].self, forKey: .options)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        step = try c.decodeIfPresent(Double.self, forKey: .step)
        on = try c.decodeIfPresent(String.self, forKey: .on)
        off = try c.decodeIfPresent(String.self, forKey: .off)
    }

    /// A range compares as numbers: a slider writes 1.00 for 1.0.
    public func isDefault(_ value: String) -> Bool {
        kind == "range" ? abs((Double(value) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : value == def
    }

    /// A value the game offers: a kept choice the game no longer offers reads as its default.
    public func accepts(_ value: String) -> Bool {
        switch kind {
        case "choice": return options?.contains { $0.first == value } ?? false
        case "range":
            // No hex: the engine's own check agrees.
            guard !value.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(value), n.isFinite,
                  let lo = min, let hi = max else { return false }
            return n >= lo && n <= hi
        case "toggle": return value == onValue || value == offValue
        default: return true
        }
    }

    /// Only rows the engine can mean something by: a `DM_` variable, a kind it draws, the fields that kind needs. Anything
    /// else would become an environment variable no launcher ever set.
    var isWellFormed: Bool {
        guard env.count > 3, env.hasPrefix("DM_"),
              env.dropFirst(3).allSatisfy({ ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "_" }) else { return false }
        switch kind {
        case "choice": return options.map { !$0.isEmpty && $0.allSatisfy { $0.count == 2 } } ?? false
        case "range": return min != nil && max != nil && (step ?? 0) > 0
        case "toggle": return true
        default: return false
        }
    }

    /// The setting this one depends on, and the value it needs.
    var dependency: (env: String, value: String)? {
        guard let needs, let eq = needs.firstIndex(of: "=") else { return nil }
        return (String(needs[..<eq]), String(needs[needs.index(after: eq)...]))
    }
}

/// A game's settings list: its framework's `dm/launcher.json` (the manifest's `launcher`).
public enum LauncherSettingsList {
    struct File: Decodable { var settings: [LauncherSetting] }

    /// The well-formed rows, in the file's order, each variable once. Empty when the game has no list or it cannot be read:
    /// the game then starts with the engine's own defaults, as before.
    public static func decode(_ data: Data) -> [LauncherSetting] {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        var seen = Set<String>()
        return file.settings.filter { $0.isWellFormed && seen.insert($0.env).inserted }
    }

    public static func load(for game: InstalledGame, fileManager: FileManager = .default) -> [LauncherSetting] {
        guard let framework = game.frameworkURL, let path = game.manifest?.launcher, SafePath.isSafeRelative(path),
              let data = BoundedRead.dataIfPresent(at: framework.appendingPathComponent(path), fileManager: fileManager)
        else { return [] }
        return decode(data)
    }
}

/// The player's choices for one game, kept in `Documents/settings/<title ID>.json`. As in the engine's launcher, only a
/// choice that differs from the game's default is kept, so a setting left alone follows the defaults of a later build.
public struct GameChoices: Equatable, Sendable {
    public var values: [String: String] = [:]
    /// The name the player gave the game, shown instead of its own. Kept here, outside the game's folder, so an update
    /// of the game keeps it too.
    public var name: String?
    /// The time spent in the game and when it was last played (`PlayClock`).
    public var playSeconds: Int = 0
    public var lastPlayed: Date?
    /// How many times the game was started, and the frames it drew in the seconds it drew any (`FrameCounter`).
    public var sessions: Int = 0
    public var fpsFrames: Int64 = 0
    public var fpsSeconds: Int = 0

    public init(values: [String: String] = [:], name: String? = nil, playSeconds: Int = 0, lastPlayed: Date? = nil,
                sessions: Int = 0, fpsFrames: Int64 = 0, fpsSeconds: Int = 0) {
        self.values = values
        self.name = name
        self.playSeconds = playSeconds
        self.lastPlayed = lastPlayed
        self.sessions = sessions
        self.fpsFrames = fpsFrames
        self.fpsSeconds = fpsSeconds
    }

    public static func url(titleID: String, documents: URL) -> URL {
        SettingsFolder.url(documents: documents).appendingPathComponent("\(titleID).json")
    }

    /// A missing or damaged file reads as no choice at all: every setting at its default.
    public static func load(titleID: String, documents: URL, fileManager: FileManager = .default) -> GameChoices {
        guard let data = BoundedRead.dataIfPresent(at: url(titleID: titleID, documents: documents), fileManager: fileManager),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return GameChoices() }
        let values = (object["values"] as? [String: Any]) ?? [:]
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let seconds = max(0, (object["play_seconds"] as? NSNumber)?.intValue ?? 0)
        let last = (object["last_played"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return GameChoices(values: values.compactMapValues { $0 as? String }, name: name, playSeconds: seconds, lastPlayed: last,
                           sessions: max(0, (object["sessions"] as? NSNumber)?.intValue ?? 0),
                           fpsFrames: max(0, (object["fps_frames"] as? NSNumber)?.int64Value ?? 0),
                           fpsSeconds: max(0, (object["fps_seconds"] as? NSNumber)?.intValue ?? 0))
    }

    public func save(titleID: String, documents: URL, fileManager: FileManager = .default) throws {
        var object: [String: Any] = ["schema": 1, "title_id": titleID, "values": values]
        if let name { object["name"] = name }
        if playSeconds > 0 { object["play_seconds"] = playSeconds }
        if let lastPlayed { object["last_played"] = ISO8601DateFormatter().string(from: lastPlayed) }
        if sessions > 0 { object["sessions"] = sessions }
        if fpsSeconds > 0 { object["fps_frames"] = fpsFrames; object["fps_seconds"] = fpsSeconds }
        try SettingsFolder.write(object, to: Self.url(titleID: titleID, documents: documents), fileManager: fileManager)
    }

    /// The game's settings and name go with it when the player erases everything.
    public static func remove(titleID: String, documents: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url(titleID: titleID, documents: documents))
    }
}

/// Why a setting cannot be changed from the screen: the engine's launcher shows such a row and keeps its value.
public enum SettingLock: Equatable, Sendable {
    /// Set by an env file (the game's `env.txt`, `Documents/env.txt` or the framework's `dm/env.txt`).
    case envFile(String)
    /// Set in the environment the app was started with (`devicectl --environment-variables`, Xcode).
    case launch
}

/// A value an env file or the launch gives a variable, and which of them.
public struct LockedValue: Equatable, Sendable {
    public var value: String
    public var lock: SettingLock
    public init(_ value: String, _ lock: SettingLock) { self.value = value; self.lock = lock }
}

/// A game's settings as the detail screen and the launch see them: the list, the player's choices and the values an env
/// file or the launch fixes. The precedence is the engine launcher's (`boot_env()` in `main.m`, `LauncherModel`): the launch
/// environment, then the env files, then the player's choice, then the game's default.
public struct GameSettings: Equatable, Sendable {
    public let list: [LauncherSetting]
    public private(set) var choices: GameChoices
    public let locks: [String: LockedValue]

    public init(list: [LauncherSetting], choices: GameChoices = GameChoices(), locks: [String: LockedValue] = [:]) {
        self.list = list
        self.choices = choices
        self.locks = locks
    }

    public func setting(_ env: String) -> LauncherSetting? { list.first { $0.env == env } }

    /// The kept choice when the game still offers it, else the game's default.
    public func chosen(_ setting: LauncherSetting) -> String {
        choices.values[setting.env].flatMap { setting.accepts($0) ? $0 : nil } ?? setting.def
    }

    /// What the game will get: a fixed value wins over the choice.
    public func value(of setting: LauncherSetting) -> String { locks[setting.env]?.value ?? chosen(setting) }

    public func lock(of setting: LauncherSetting) -> SettingLock? { locks[setting.env]?.lock }

    /// Keeps a choice, or forgets it when it is the game's default. False for a value the game does not offer, or a setting
    /// an env file or the launch fixes.
    @discardableResult
    public mutating func choose(_ env: String, _ value: String) -> Bool {
        guard let setting = self.setting(env), setting.accepts(value), locks[env] == nil else { return false }
        choices.values[env] = setting.isDefault(value) ? nil : value
        return true
    }

    /// Every setting back to the game's tested defaults (the fixed ones stay what fixes them).
    public mutating func reset() { choices.values = [:] }

    /// A kept choice the game still offers: what Reset would bring back to the default.
    public var hasChoices: Bool {
        list.contains { s in choices.values[s.env].map { s.accepts($0) && locks[s.env] == nil } ?? false }
    }

    /// A sub-setting is shown only while the setting it depends on has the value it needs; one that names a setting this
    /// game does not have stays shown (`LauncherModel.visible`).
    public func isVisible(_ setting: LauncherSetting) -> Bool {
        guard let dependency = setting.dependency, let parent = self.setting(dependency.env) else { return true }
        return value(of: parent) == dependency.value
    }

    /// The sections in the list's order, each with its visible rows, leaving out `excluding`.
    public func sections(excluding: Set<String> = []) -> [(title: String, rows: [LauncherSetting])] {
        var titles: [String] = []
        for s in list where !titles.contains(s.sectionTitle) { titles.append(s.sectionTitle) }
        return titles.compactMap { title in
            let rows = list.filter { $0.sectionTitle == title && !excluding.contains($0.env) && isVisible($0) }
            return rows.isEmpty ? nil : (title, rows)
        }
    }

    /// What the launch puts in the environment: every setting nothing else fixes, at the player's choice or the game's
    /// default, as the engine launcher's Play does (`LauncherModel.apply`). Defaults go in too, so the log lists them all.
    public var environment: [String: String] {
        var environment: [String: String] = [:]
        for s in list where locks[s.env] == nil { environment[s.env] = chosen(s) }
        return environment
    }
}
