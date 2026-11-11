import Foundation
import NXPocketKit

/// What to build, in the engine's own terms. The launcher never rewrites the engine's output: it stages the game's
/// framework, keeps the RomFS image aside, and packs what it finds.
public struct EngineBuildRequest: Sendable {
    public var gameFolder: URL
    public var keysFile: URL?
    public var titleID: String?
    /// `--package v<N>`: the version to build when it is not the newest among the files (`BuildPlan`).
    public var packageVersion: String?
    public var language: String?
    public var keepExtracted: Bool
    public var allowOtherMetal: Bool
    public var stagingFolder: URL
    public var workFolder: URL?
    /// Whether the files given hold DLC. The engine's `aoc/` stays from an earlier run when this one has none, so
    /// it is packed only when this run made it.
    public var includesDLC: Bool

    public init(gameFolder: URL, keysFile: URL? = nil, titleID: String? = nil, packageVersion: String? = nil,
                language: String? = nil, keepExtracted: Bool = true, allowOtherMetal: Bool = false,
                stagingFolder: URL, workFolder: URL? = nil, includesDLC: Bool = true) {
        self.gameFolder = gameFolder
        self.keysFile = keysFile
        self.titleID = titleID
        self.packageVersion = packageVersion
        self.language = language
        self.keepExtracted = keepExtracted
        self.allowOtherMetal = allowOtherMetal
        self.stagingFolder = stagingFolder
        self.workFolder = workFolder
        self.includesDLC = includesDLC
    }
}

public enum EngineEvent: Sendable {
    /// Stage `index` of `count`, and the step it starts with (often empty).
    case stage(index: Int, count: Int?, name: String, step: String)
    /// A new step within the current stage: "cache check", then "compiling", for the shaders.
    case step(name: String, step: String)
    case progress(name: String, step: String?, done: Double?, total: Double?, unit: String?,
                  note: String?, fraction: Double?, eta: Double?, elapsed: Double?)
    case stageEnd(index: Int, name: String, ok: Bool, summary: String, warn: Bool)
    case message(String)
    case raw(String)
}

/// The engine's `--progress json` events, as its `Progress` class writes them (engine `scripts/build_ipa_from_nsp.py`):
/// `stage` (k of n), `step`, `progress`, `stage_end` and `say`. A step is a name, never a number.
public enum EngineEventParser {
    public static func parse(line: String) -> EngineEvent {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .raw(line)
        }
        let event = object["ev"] as? String ?? ""
        switch event {
        case "stage":
            return .stage(index: int(object["k"]) ?? 0, count: int(object["n"]), name: object["name"] as? String ?? "",
                          step: text(object["step"]) ?? "")
        case "step":
            return .step(name: object["name"] as? String ?? "", step: text(object["step"]) ?? "")
        case "progress":
            return .progress(name: object["name"] as? String ?? "",
                             step: text(object["step"]),
                             done: double(object["done"]),
                             total: double(object["total"]),
                             unit: object["unit"] as? String,
                             note: object["note"] as? String,
                             fraction: double(object["frac"]),
                             eta: double(object["eta"]),
                             elapsed: double(object["elapsed"]) ?? 0)
        case "stage_end":
            return .stageEnd(index: int(object["k"]) ?? 0,
                             name: object["name"] as? String ?? "",
                             ok: object["ok"] as? Bool ?? false,
                             summary: object["summary"] as? String ?? "",
                             warn: object["warn"] as? Bool ?? false)
        case "say":
            return .message(object["msg"] as? String ?? "")
        default:
            return .raw(line)
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// What the build screen shows from the engine's events: the stage as "k/n name", the bar of that stage, the bar of
/// the whole build, and under them the step and its count. Each stage, and each step, starts its own bar from zero.
///
/// The engine already sends a count change at most twice a second, so every progress event is shown. The screen
/// used to skip any value that was not 1% above the last one shown, and never reset that at a new stage: the engine
/// caps a stage at 0.99, so after the first stage that got there, every later one stayed at 0% (a 14,388-shader
/// compile showed 0% at 97%). Many stages carry no count at all (the extraction of a version, the framework's Xcode
/// build), so their own bar cannot move: the whole build's bar, stage k of n, moves at each of them.
public struct BuildProgress: Equatable, Sendable {
    public private(set) var stage: String
    public private(set) var fraction: Double = 0
    public private(set) var detail: String
    /// Stage k of n (1-based) once the engine has said how many there are.
    public private(set) var stageIndex = 0
    public private(set) var stageCount = 0
    /// Whether the current stage has a count, so its own bar means something.
    public private(set) var stageHasCount = false

    public init(stage: String = "starting", detail: String = "") {
        self.stage = stage
        self.detail = detail
    }

    /// The whole build: the stages done, plus the current one's share. Never backwards: the engine can add a stage
    /// it did not plan (a provisional profile's heap check), which would otherwise pull the bar back.
    public private(set) var overall: Double = 0

    /// True when the event changes what the screen shows.
    @discardableResult
    public mutating func apply(_ event: EngineEvent) -> Bool {
        switch event {
        case .stage(let index, let count, let name, let step):
            stage = count.map { "\(index)/\($0) · \(name)" } ?? name
            fraction = 0
            detail = step
            stageIndex = index
            stageCount = count ?? stageCount
            stageHasCount = false
        case .step(_, let step):
            fraction = 0
            detail = step
        case .progress(_, let step, let done, let total, let unit, let note, let value, _, _):
            fraction = min(max(value ?? 0, 0), 1)
            stageHasCount = value != nil
            detail = Self.detail(step: step, done: done, total: total, unit: unit, note: note)
        case .stageEnd(let index, _, _, _, _):
            guard stageCount > 0 else { return false }
            stageIndex = max(stageIndex, index)
            fraction = 1
            overall = max(overall, min(Double(stageIndex) / Double(stageCount), 1))
            return true
        default:
            return false
        }
        if stageCount > 0, stageIndex > 0 {
            overall = max(overall, min((Double(stageIndex - 1) + fraction) / Double(stageCount), 1))
        }
        return true
    }

    /// "compiling · 13924 / 14388 shaders · 464 not cached", leaving out what the event does not carry.
    static func detail(step: String?, done: Double?, total: Double?, unit: String?, note: String?) -> String {
        var parts: [String] = []
        if let step, !step.isEmpty { parts.append(step) }
        if let done {
            let format = { (value: Double) -> String in
                unit == "B" ? ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) : String(Int(value))
            }
            let count = total.map { "\(format(done)) / \(format($0))" } ?? format(done)
            parts.append(unit.map { $0 == "B" || $0.isEmpty ? count : "\(count) \($0)" } ?? count)
        }
        if let note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

public struct EngineBuildOutput: Sendable {
    public var framework: URL
    public var manifest: GameManifest
    public var romfsImage: URL?
    public var aocFolder: URL?
}

/// Runs `engine/scripts/build_ipa_from_nsp.py` in route C: the game's framework only, its data kept aside.
public final class EngineBuilder: @unchecked Sendable {
    public let toolchain: Toolchain

    public init(toolchain: Toolchain) {
        self.toolchain = toolchain
    }

    public func arguments(_ request: EngineBuildRequest) -> [String] {
        var arguments = [toolchain.engine.buildScript.path, request.gameFolder.path,
                         "--shell-framework", request.stagingFolder.path,
                         "--romfs", "separate",
                         "--progress", "json"]
        if let keys = request.keysFile { arguments += ["-k", keys.path] }
        if let titleID = request.titleID, !titleID.isEmpty { arguments += ["--title-id", titleID] }
        if let version = request.packageVersion, !version.isEmpty { arguments += ["--package", version] }
        if let language = request.language, !language.isEmpty { arguments += ["-l", language] }
        arguments.append(request.keepExtracted ? "--keep-extracted" : "--no-keep-extracted")
        if request.allowOtherMetal { arguments.append("--allow-other-metal") }
        if let work = request.workFolder { arguments += ["--work-dir", work.path] }
        return arguments
    }

    public func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let xcode = toolchain.xcode {
            environment["DEVELOPER_DIR"] = xcode.appendingPathComponent("Contents/Developer").path
        }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }

    /// Starts the engine. `onEvent` gets every line in order, and `onFinish` comes after the last one: a caller that
    /// waits for it has seen the engine's reasons and its `game files:` line.
    public func start(_ request: EngineBuildRequest, onEvent: @escaping (EngineEvent) -> Void,
                      onFinish: @escaping (Int32) -> Void = { _ in }) throws -> ProcessRunner {
        guard toolchain.engine.isUsable else {
            throw NXPocketError(.engineMissing, "the engine is not synced: \(toolchain.engine.root.path)")
        }
        try FileManager.default.createDirectory(at: request.stagingFolder, withIntermediateDirectories: true)
        let runner = ProcessRunner(executable: toolchain.python,
                                   arguments: arguments(request),
                                   currentDirectory: toolchain.engine.root,
                                   environment: environment())
        runner.onLine = { line in onEvent(EngineEventParser.parse(line: line)) }
        runner.onExit = onFinish
        try runner.start()
        return runner
    }

    /// What the engine left behind: `<staging>/DmGame<title ID>.framework`, the RomFS image its `game files:` line
    /// named, and its `aoc/` when this run had DLC.
    ///
    /// The image comes from that line only. The launcher used to fall back on the newest `romfs.img` under the build
    /// folder, which with several versions extracted and none rewritten by this run can be another version's, packed
    /// without a word; the line is now always read, since the runner delivers every line before the end.
    public func outputs(for request: EngineBuildRequest, reportedRomfs: URL?) throws -> EngineBuildOutput {
        guard let framework = Self.framework(in: request.stagingFolder) else {
            throw NXPocketError(.engineFailed, "the engine produced no framework in \(request.stagingFolder.path)")
        }
        let manifest = try GameManifest.decode(try BoundedRead.data(at: framework.appendingPathComponent(GameManifest.fileName)))
        guard let image = reportedRomfs else {
            throw NXPocketError(.engineFailed, "the engine did not name the game's RomFS image (its \"game files:\" line)")
        }
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw NXPocketError(.engineFailed, "the RomFS image the engine named is not there", path: image.path)
        }
        return EngineBuildOutput(framework: framework, manifest: manifest, romfsImage: image,
                                 aocFolder: request.includesDLC ? Self.addOnFolder(romfsImage: image, workFolder: request.workFolder) : nil)
    }

    /// The RomFS image in the engine's `game files: <path>` line, which names the version it packed: with several
    /// versions extracted, the newest file is not always the one built.
    public static func romfsImage(inMessage message: String) -> URL? {
        let prefix = "game files: "
        guard message.hasPrefix(prefix) else { return nil }
        let path = String(message.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/"), path.lowercased().hasSuffix(".img") else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func framework(in staging: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        return entries.first { entry in
            entry.pathExtension == "framework"
                && FileManager.default.fileExists(atPath: entry.appendingPathComponent(GameManifest.fileName).path)
        }
    }

    /// The engine extracts each DLC to `<build folder>/aoc/<index>.img` (`extract_aoc`), the build folder being
    /// the one above `extract/<version>/RomFS.img`.
    public static func addOnFolder(romfsImage: URL?, workFolder: URL?) -> URL? {
        guard let work = workFolder ?? romfsImage?.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent() else { return nil }
        let aoc = work.appendingPathComponent("aoc", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: aoc.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return aoc
    }
}
