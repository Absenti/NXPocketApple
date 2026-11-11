import Foundation
import NXPocketKit

/// What starting one game's engine means: the environment it reads before anything else, the `dm_main` arguments, the
/// framework to load and the marker that proves the loaded image is the game's. Mirrors `boot_env()` in the engine's
/// `dm/ios/Sources/main.m` and NX2Apple's `EngineLaunchPlan` (docs/launcher-c-plan.md, "Environment at game start").
public struct EngineLaunchPlan: Sendable {
    public var environment: [String: String]
    public var arguments: [String]
    /// The game's framework folder: the executable has to be a file inside it (`checkExecutable`).
    public var framework: URL
    public var frameworkExecutable: URL
    public var imageMarker: String
    public var logURL: URL
    public var workingDirectory: URL
    public var foldersToCreate: [URL]

    /// The game's own folder is the package the Mac app sent; `data` holds the RomFS image and the add-on content.
    ///
    /// Who decides a variable, first to last, as the engine's own launcher does (`boot_env()` in `main.m`, `LauncherModel`):
    /// the paths this shell computes; the launch environment (`launchEnvironment`, its `DM_` keys); the env files (the game's
    /// `env.txt`, `Documents/env.txt` (`envFileText` when given), the framework's `dm/env.txt`); the player's per-game choices
    /// or the game's defaults (`settings`); the touch controls' options, one set for every game (`touch`). The engine's
    /// launcher shows a setting an env file or the launch fixed and keeps it: `DM_ENV_FILE_KEYS` and `DM_ENV_LAUNCH_KEYS`
    /// list them, as `main.m` does. `touchHint` is the right-stick hint in the player's language. The log is this start's
    /// own, named after `now` (`GameLogs`).
    public static func make(game: InstalledGame, documents: URL, appResources: URL,
                            envFileText: String? = nil, settings: GameSettings? = nil, touch: TouchControls? = nil,
                            touchHint: String? = nil, launchEnvironment: [String: String] = [:], now: Date = Date(),
                            fileManager: FileManager = .default) -> EngineLaunchPlan? {
        guard let framework = game.frameworkURL, let manifest = game.manifest else { return nil }
        let folder = game.directory
        func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        func first(_ candidates: [URL]) -> URL? { candidates.first(where: isDirectory) }

        var environment: [String: String] = [:]
        let perGameProfile = folder.appendingPathComponent("profile.tsv")
        environment["DM_PROFILE"] = (fileManager.fileExists(atPath: perGameProfile.path)
            ? perGameProfile : framework.appendingPathComponent(manifest.profile)).path
        if fileManager.fileExists(atPath: game.romfsURL.path) {
            environment["DM_ROMFS"] = game.romfsURL.path
        }
        let save = folder.appendingPathComponent("save", isDirectory: true)
        let temp = folder.appendingPathComponent("temp", isDirectory: true)
        environment["DM_SAVE"] = save.path
        environment["DM_TEMP"] = temp.path
        environment["DM_NVN_SHMAP"] = framework.appendingPathComponent(manifest.shaderMap).path

        // The game's own copies of the shader libraries and the pipeline archive win over the framework's, so an
        // update of one does not mean re-signing the framework.
        let ownMSL = folder.appendingPathComponent("msl", isDirectory: true)
        let bundledMSL = framework.appendingPathComponent("msl", isDirectory: true)
        if let msl = first([ownMSL, bundledMSL]) { environment["DM_MSL_DIR"] = msl.path }
        if let pso = first([folder.appendingPathComponent("pso", isDirectory: true),
                            framework.appendingPathComponent("pso", isDirectory: true)]) {
            environment["DM_PSO_BUNDLE"] = pso.path
        }
        if let aoc = first([game.aocURL, folder.appendingPathComponent("aoc", isDirectory: true)]) {
            environment["DM_AOC_DIR"] = aoc.path
        }
        environment["DM_CHEATS"] = folder.appendingPathComponent("cheats", isDirectory: true).path
        environment["DM_FONT_DIR"] = appResources.appendingPathComponent("dm/font", isDirectory: true).path
        // The shell already showed its own library, so the per-game launcher screen stays out of the way.
        environment["DM_LAUNCHER"] = "0"

        var fromFile: [String] = [], fromLaunch: [String] = []
        for (key, fixed) in presets(game: game, documents: documents, envFileText: envFileText,
                                    launchEnvironment: launchEnvironment, fileManager: fileManager)
            where environment[key] == nil {
            environment[key] = fixed.value
            if fixed.lock == .launch { fromLaunch.append(key) } else { fromFile.append(key) }
        }
        let settings = settings ?? GameSettings(list: LauncherSettingsList.load(for: game, fileManager: fileManager),
                                                choices: GameChoices.load(titleID: game.titleID.description,
                                                                          documents: documents, fileManager: fileManager))
        for (key, value) in settings.environment where environment[key] == nil { environment[key] = value }
        let touch = touch ?? TouchControls.load(documents: documents, fileManager: fileManager)
        for (key, value) in touch.environment(hint: touchHint) where environment[key] == nil { environment[key] = value }
        environment["DM_ENV_FILE_KEYS"] = fromFile.joined(separator: " ")
        environment["DM_ENV_LAUNCH_KEYS"] = fromLaunch.joined(separator: " ")

        return EngineLaunchPlan(environment: environment,
                                arguments: ["dmhost", framework.appendingPathComponent("dm", isDirectory: true).path]
                                    + manifest.modules,
                                framework: framework,
                                frameworkExecutable: framework.appendingPathComponent(manifest.frameworkExecutable),
                                imageMarker: manifest.imageMarker,
                                logURL: GameLogs.newLogURL(titleID: game.titleID.description, documents: documents,
                                                           now: now, fileManager: fileManager),
                                workingDirectory: documents,
                                foldersToCreate: [save, temp])
    }

    /// The values the launch environment and the env files give, in the order they win, each variable once: the launch
    /// environment's `DM_` keys, then the game's `env.txt`, `Documents/env.txt` (`envFileText` when given) and the
    /// framework's `dm/env.txt`. The detail screen shows a setting found here as fixed, and the launch passes these before the
    /// player's choices.
    public static func presets(game: InstalledGame, documents: URL, envFileText: String? = nil,
                               launchEnvironment: [String: String] = [:],
                               fileManager: FileManager = .default) -> [(key: String, value: LockedValue)] {
        func text(at url: URL) -> String? {
            BoundedRead.dataIfPresent(at: url, fileManager: fileManager).flatMap { String(data: $0, encoding: .utf8) }
        }
        var result: [(key: String, value: LockedValue)] = []
        var seen = Set<String>()
        for key in launchEnvironment.keys.sorted() where key.hasPrefix("DM_") && seen.insert(key).inserted {
            result.append((key, LockedValue(launchEnvironment[key] ?? "", .launch)))
        }
        var files: [(name: String, text: String?)] = [
            ("games/\(game.titleID)/env.txt", text(at: game.directory.appendingPathComponent("env.txt"))),
            ("env.txt", envFileText ?? text(at: documents.appendingPathComponent("env.txt")))
        ]
        if let framework = game.frameworkURL {
            files.append(("dm/env.txt", text(at: framework.appendingPathComponent("dm/env.txt"))))
        }
        // Only the engine's own variables: an env file in a package or in Files must not set HOME, TMPDIR, DYLD_* or
        // MTL_* for the whole process.
        for file in files {
            for (key, value) in parseEnvFile(file.text ?? "") where key.hasPrefix("DM_") && seen.insert(key).inserted {
                result.append((key, LockedValue(value, .envFile(file.name))))
            }
        }
        return result
    }

    /// `KEY=VALUE` lines in order: `#` starts a comment, a blank line or one without `=` is skipped.
    public static func parseEnvFile(_ text: String) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "="), separator != line.startIndex else { continue }
            result.append((key: String(line[..<separator]), value: String(line[line.index(after: separator)...])))
        }
        return result
    }

    /// Before the executable is loaded: it has to be a regular file inside the game's framework folder, links resolved.
    /// The manifest is a file in `Documents`, which Files can change after the import checked it, and `dlopen` loads
    /// whatever path it is given.
    public func checkExecutable(fileManager: FileManager = .default) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: frameworkExecutable.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw NXPocketError(.packageDamaged, "\(frameworkExecutable.lastPathComponent) is not a regular file in the framework",
                                path: frameworkExecutable.path)
        }
        guard SafePath.contains(frameworkExecutable, in: framework),
              frameworkExecutable.resolvingSymlinksInPath().standardizedFileURL != framework.resolvingSymlinksInPath().standardizedFileURL else {
            throw NXPocketError(.unsafePath, "the executable the manifest names is outside \(framework.lastPathComponent)",
                                path: frameworkExecutable.path)
        }
    }

    /// The save and temp folders. The temp folder is kept out of the backup; the save folder stays in it.
    public func createFolders(fileManager: FileManager = .default) throws {
        for url in foldersToCreate {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            if url.lastPathComponent != "save" { BackupExclusion.exclude(url) }
        }
    }
}

/// The `DM_` variables the app was started with (`devicectl device process launch --environment-variables`, Xcode),
/// read once before this app sets any of its own (`FrameworkEngineHost.prepareProcess`): they win over the env files and
/// the player's choices, as they do in the engine's own app.
public enum LaunchEnvironment {
    public static let values: [String: String] = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("DM_") }
}
