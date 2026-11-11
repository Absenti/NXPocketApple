import Foundation
import SwiftUI

/// Everything the launcher remembers between launches.
public struct LauncherSettings: Codable, Equatable, Sendable {
    public var engineRoot: String = ""
    public var keysFile: String = ""
    public var outputFolder: String = ""
    public var gameFolder: String = ""
    public var bundleID: String = "dev.nxpocket.app"
    public var language: String = ""
    public var keepExtracted: Bool = true
    public var allowOtherMetal: Bool = false
    public var deleteSource: Bool = false
    public var xcodePath: String = ""
    public var deviceUDID: String = ""
    /// A Python to run the engine with, ahead of the ones the launcher looks for. Blank lets it choose.
    public var pythonPath: String = ""
    /// Whether a game the queue has built goes to the chosen iPhone right after.
    public var sendAfterBuild: Bool = true
    /// Whether the saves of the games on the iPhone are copied to the Mac by themselves once they changed
    /// (`SaveWatch`), whenever the launcher sees the phone.
    public var autoBackup: Bool = true
    /// Whether the launcher looks for a new release of itself at launch, at most once a day.
    public var checkUpdates: Bool = true
    /// When it last looked (seconds since 1970).
    public var lastUpdateCheck: Double = 0
    /// Where the engine's `<title ID>_build` folders go (extracted files, shader cache: gigabytes). Blank puts each
    /// beside its base game, in the dumps folder; set, the dumps folder is only read.
    public var workFolder: String = ""
    /// Names the user gave games, by title ID: written into each package built for them (`PackageRenamer`).
    public var gameNames: [String: String] = [:]
    /// Each renamed game's own name, from its first package, so a rename can be undone.
    public var originalGameNames: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case engineRoot, keysFile, outputFolder, gameFolder, bundleID, language, keepExtracted, allowOtherMetal
        case deleteSource, xcodePath, deviceUDID, pythonPath, sendAfterBuild, autoBackup, gameNames, originalGameNames
        case workFolder, checkUpdates, lastUpdateCheck
    }

    /// Every field is optional on the way in: the synthesised decoder requires them all, so adding one would have
    /// made every saved settings blob undecodable, and the launcher would have started from defaults, forgetting the
    /// keys, the game folder and the device.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LauncherSettings()
        engineRoot = try container.decodeIfPresent(String.self, forKey: .engineRoot) ?? defaults.engineRoot
        keysFile = try container.decodeIfPresent(String.self, forKey: .keysFile) ?? defaults.keysFile
        outputFolder = try container.decodeIfPresent(String.self, forKey: .outputFolder) ?? defaults.outputFolder
        gameFolder = try container.decodeIfPresent(String.self, forKey: .gameFolder) ?? defaults.gameFolder
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID) ?? defaults.bundleID
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language
        keepExtracted = try container.decodeIfPresent(Bool.self, forKey: .keepExtracted) ?? defaults.keepExtracted
        allowOtherMetal = try container.decodeIfPresent(Bool.self, forKey: .allowOtherMetal) ?? defaults.allowOtherMetal
        deleteSource = try container.decodeIfPresent(Bool.self, forKey: .deleteSource) ?? defaults.deleteSource
        xcodePath = try container.decodeIfPresent(String.self, forKey: .xcodePath) ?? defaults.xcodePath
        deviceUDID = try container.decodeIfPresent(String.self, forKey: .deviceUDID) ?? defaults.deviceUDID
        pythonPath = try container.decodeIfPresent(String.self, forKey: .pythonPath) ?? defaults.pythonPath
        sendAfterBuild = try container.decodeIfPresent(Bool.self, forKey: .sendAfterBuild) ?? defaults.sendAfterBuild
        autoBackup = try container.decodeIfPresent(Bool.self, forKey: .autoBackup) ?? defaults.autoBackup
        checkUpdates = try container.decodeIfPresent(Bool.self, forKey: .checkUpdates) ?? defaults.checkUpdates
        lastUpdateCheck = try container.decodeIfPresent(Double.self, forKey: .lastUpdateCheck) ?? defaults.lastUpdateCheck
        gameNames = try container.decodeIfPresent([String: String].self, forKey: .gameNames) ?? defaults.gameNames
        workFolder = try container.decodeIfPresent(String.self, forKey: .workFolder) ?? defaults.workFolder
        originalGameNames = try container.decodeIfPresent([String: String].self, forKey: .originalGameNames) ?? defaults.originalGameNames
    }

    public var pythonURL: URL? {
        pythonPath.isEmpty ? nil : URL(fileURLWithPath: (pythonPath as NSString).expandingTildeInPath)
    }

    public static let defaultBundleID = "dev.nxpocket.app"

    public static var defaultOutputFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/NXPocket", isDirectory: true)
    }

    public var outputURL: URL {
        outputFolder.isEmpty ? Self.defaultOutputFolder : URL(fileURLWithPath: (outputFolder as NSString).expandingTildeInPath)
    }

    public var keysURL: URL? {
        keysFile.isEmpty ? nil : URL(fileURLWithPath: (keysFile as NSString).expandingTildeInPath)
    }

    public var gameURL: URL? {
        gameFolder.isEmpty ? nil : URL(fileURLWithPath: (gameFolder as NSString).expandingTildeInPath)
    }

    public var workURL: URL? {
        workFolder.isEmpty ? nil : URL(fileURLWithPath: (workFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var xcodeURL: URL? {
        xcodePath.isEmpty ? nil : URL(fileURLWithPath: (xcodePath as NSString).expandingTildeInPath)
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var value: LauncherSettings {
        didSet { if value != oldValue { save() } }
    }

    private let defaults: UserDefaults
    private static let key = "dev.nxpocket.launcher.settings"

    /// The domain the launcher kept its settings in while it ran as a plain executable (`swift build`): a bundle's
    /// standard defaults are its bundle ID's, so the .app would otherwise start from nothing (no keys, folders, device).
    static let plainExecutableDomain = "iPorterNX"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults === UserDefaults.standard, defaults.data(forKey: Self.key) == nil,
           let bundleID = Bundle.main.bundleIdentifier, bundleID != Self.plainExecutableDomain,
           let earlier = UserDefaults(suiteName: Self.plainExecutableDomain)?.data(forKey: Self.key) {
            defaults.set(earlier, forKey: Self.key)
        }
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(LauncherSettings.self, from: data) {
            value = decoded
        } else {
            value = LauncherSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func reset() { value = LauncherSettings() }
}
