import Foundation
import NXPocketKit

/// The tools the launcher needs from the machine: Xcode's own, a real Python, and the engine.
public struct Toolchain: Sendable {
    public var xcrun: URL
    public var python: URL
    public var xcode: URL?
    public var engine: EngineLocation
    /// What the chosen Python is missing of the engine's modules (`PythonEnvironment.requiredModules`), empty when
    /// it has them all.
    public var pythonMissing: [String] = []
    public var pythonVersion: String = "?"

    public static let empty = Toolchain(xcrun: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                        python: URL(fileURLWithPath: "/usr/bin/python3"),
                                        xcode: nil, engine: .empty)

    public init(xcrun: URL, python: URL, xcode: URL?, engine: EngineLocation,
                pythonMissing: [String] = [], pythonVersion: String = "?") {
        self.xcrun = xcrun
        self.python = python
        self.xcode = xcode
        self.engine = engine
        self.pythonMissing = pythonMissing
        self.pythonVersion = pythonVersion
    }
}

/// A Python the engine could run in, and what it lacks.
///
/// The engine's build script imports lz4, capstone, fontTools, zbic and a zstd module, and needs nsz for an NSZ or
/// XCZ game; it stops on the first one missing. The launcher takes the first Python 3.12+ that has them all, from the places
/// such a Python lives.
public struct PythonEnvironment: Sendable, Equatable {
    public var url: URL
    public var major: Int
    public var minor: Int
    public var missing: [String]

    public init(url: URL, major: Int, minor: Int, missing: [String]) {
        self.url = url
        self.major = major
        self.minor = minor
        self.missing = missing
    }

    /// What the engine imports, by the name `pip install` knows it under. `zstd` stands for compression.zstd
    /// (Python 3.14) or backports.zstd before it.
    public static let requiredModules = ["lz4", "capstone", "fontTools", "zbic", "zstd", "nsz"]

    /// The engine's own floor (build_ipa_from_nsp.py: "Python 3.12+ is required").
    public var isRecentEnough: Bool { major > 3 || (major == 3 && minor >= 12) }
    public var isComplete: Bool { isRecentEnough && missing.isEmpty }
    public var versionText: String { "\(major).\(minor)" }

    /// One process per candidate: its version on the first line, then each missing module on a line of its own.
    static let probe = """
        import importlib.util as u, sys
        print('%d.%d' % sys.version_info[:2])
        def has(m):
            try: return u.find_spec(m) is not None
            except Exception: return False
        for name, mods in (('lz4', ['lz4.block']), ('capstone', ['capstone']), ('fontTools', ['fontTools']),
                           ('zbic', ['zbic']), ('zstd', ['compression.zstd', 'backports.zstd']), ('nsz', ['nsz'])):
            if not any(has(m) for m in mods): print('missing', name)
        """

    public static func inspect(_ url: URL) -> PythonEnvironment? {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let result = try? ProcessRunner.capture(url, ["-I", "-c", probe], timeout: 20),
              let first = result.lines.first(where: { $0.contains(".") && !$0.hasPrefix("missing") }) else { return nil }
        let parts = first.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let missing = result.lines.compactMap { line -> String? in
            line.hasPrefix("missing ") ? String(line.dropFirst("missing ".count)) : nil
        }
        return PythonEnvironment(url: url, major: parts[0], minor: parts[1], missing: missing)
    }
}

/// Where the engine is: the NX2Apple checkout, or a bundled copy of it.
public struct EngineLocation: Sendable, Equatable {
    public var root: URL
    public var scripts: URL
    public var tools: URL

    public static let empty = EngineLocation(root: URL(fileURLWithPath: "/nonexistent"),
                                             scripts: URL(fileURLWithPath: "/nonexistent"),
                                             tools: URL(fileURLWithPath: "/nonexistent"))

    public init(root: URL, scripts: URL, tools: URL) {
        self.root = root
        self.scripts = scripts
        self.tools = tools
    }

    public init(root: URL) {
        self.init(root: root,
                  scripts: root.appendingPathComponent("scripts", isDirectory: true),
                  tools: root.appendingPathComponent("dm/tools", isDirectory: true))
    }

    public var buildScript: URL { scripts.appendingPathComponent("build_ipa_from_nsp.py") }
    public var romfsTool: URL { tools.appendingPathComponent("romfs_image.py") }
    public var isUsable: Bool { FileManager.default.fileExists(atPath: buildScript.path) }
}

public enum ToolchainLocator {
    /// The environment the setup screen (`FirstRunSetup.installPython`) or `tools/setup_python.sh` makes for the
    /// launcher, and the first place it looks after Settings.
    public static var ownEnvironment: URL { SetupPaths.standard.venvPython }

    /// Where a Python with the engine's modules is found, best first: the one named in Settings, the launcher's own
    /// environment, one beside the engine, NX2Apple's own builder app's, then the system's. A GUI app does not get the
    /// shell's PATH, so these are looked for by path.
    public static func pythonCandidates(preferred: URL?, engine: EngineLocation) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        if let preferred { candidates.append(preferred) }
        candidates.append(ownEnvironment)
        candidates.append(engine.root.appendingPathComponent(".venv/bin/python3"))
        candidates.append(home.appendingPathComponent("Library/Application Support/NS Port Builder/venv/bin/python3"))
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func detect(engineRoot: URL?, preferredXcode: URL? = nil, preferredPython: URL? = nil) -> Toolchain {
        let engine = engineRoot.map(EngineLocation.init(root:)) ?? defaultEngine()
        let chosen = python(candidates: pythonCandidates(preferred: preferredPython, engine: engine))
        let missing: [String]
        if let chosen {
            missing = chosen.isRecentEnough ? chosen.missing : ["Python 3.12 or later"]
        } else {
            missing = ["Python 3.12 or later"]
        }
        return Toolchain(xcrun: URL(fileURLWithPath: "/usr/bin/xcrun"),
                         python: chosen?.url ?? URL(fileURLWithPath: "/usr/bin/python3"),
                         xcode: preferredXcode ?? xcodeInstallations().first,
                         engine: engine, pythonMissing: missing, pythonVersion: chosen?.versionText ?? "?")
    }

    /// The first complete candidate; failing that, the recent one that lacks the fewest modules, so the report
    /// names what to install rather than "no Python".
    public static func python(candidates: [URL],
                              inspect: (URL) -> PythonEnvironment? = PythonEnvironment.inspect) -> PythonEnvironment? {
        var best: PythonEnvironment?
        for url in candidates {
            guard let environment = inspect(url) else { continue }
            if environment.isComplete { return environment }
            guard let current = best else {
                best = environment
                continue
            }
            if environment.isRecentEnough && (!current.isRecentEnough || environment.missing.count < current.missing.count) {
                best = environment
            }
        }
        return best
    }

    public static func python(preferred: URL?) -> URL {
        python(candidates: pythonCandidates(preferred: preferred, engine: defaultEngine()))?.url
            ?? URL(fileURLWithPath: "/usr/bin/python3")
    }

    public static func pythonVersion(at url: URL) -> (Int, Int)? {
        guard let result = try? ProcessRunner.capture(url, ["-c", "import sys;print('%d.%d' % sys.version_info[:2])"],
                                                      timeout: 10) else { return nil }
        guard let first = result.lines.first(where: { $0.contains(".") }) else { return nil }
        let parts = first.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// The app bundle is inside the checkout while developing; otherwise look beside the repository.
    public static func defaultEngine() -> EngineLocation {
        let candidates = engineCandidates()
        for candidate in candidates {
            let location = EngineLocation(root: candidate)
            if location.isUsable { return location }
        }
        return candidates.first.map(EngineLocation.init(root:)) ?? .empty
    }

    /// Every place an engine is looked for, in the order the first usable one is taken when Settings names none.
    public static func engineCandidates() -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["NXPOCKET_ENGINE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        var directory = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(directory.appendingPathComponent("engine", isDirectory: true))
            candidates.append(directory.appendingPathComponent("third_party/NX2Apple/engine", isDirectory: true))
            directory = directory.deletingLastPathComponent()
        }
        // The one the setup screen fetches when none of the above is there (`FirstRunSetup.installEngine`).
        candidates.append(SetupPaths.standard.engine)
        return candidates
    }

    /// Every Xcode the machine has, newest first, so 27.2 can be chosen over the App Store's build.
    public static func xcodeInstallations() -> [URL] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/Shared/Applications")]
        var found: [(url: URL, version: [Int])] = []
        for root in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.pathExtension == "app" && entry.lastPathComponent.hasPrefix("Xcode") {
                guard let version = xcodeVersion(entry) else { continue }
                found.append((entry, version))
            }
        }
        return newestFirst(found)
    }

    /// Newest first, by the version Xcode states, not by its name: by name, "Xcode.app" came before
    /// "Xcode 27.2.app" (a dot sorts after a space), whatever either was. Equal versions keep the name order.
    static func newestFirst(_ found: [(url: URL, version: [Int])]) -> [URL] {
        func padded(_ version: [Int], to count: Int) -> [Int] { version + Array(repeating: 0, count: max(0, count - version.count)) }
        return found.sorted { lhs, rhs in
            let count = max(lhs.version.count, rhs.version.count)
            let left = padded(lhs.version, to: count), right = padded(rhs.version, to: count)
            if left != right { return right.lexicographicallyPrecedes(left) }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }.map(\.url)
    }

    /// `CFBundleShortVersionString` of `Contents/version.plist`, as numbers: [27, 2]. Nil when it is not an Xcode.
    static func xcodeVersion(_ xcode: URL) -> [Int]? {
        guard let data = try? BoundedRead.data(at: xcode.appendingPathComponent("Contents/version.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let text = plist["CFBundleShortVersionString"] as? String else { return nil }
        let numbers = text.split(separator: ".").compactMap { Int($0) }
        return numbers.isEmpty ? nil : numbers
    }

    /// The SDK version the chosen Xcode carries, for the app's own report.
    public static func sdkVersion(xcode: URL?) -> String? {
        var environment = ProcessInfo.processInfo.environment
        if let xcode { environment["DEVELOPER_DIR"] = xcode.appendingPathComponent("Contents/Developer").path }
        var toolchain = Toolchain.empty
        toolchain.python = URL(fileURLWithPath: "/usr/bin/env")
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                   arguments: ["--sdk", "iphoneos", "--show-sdk-version"], environment: environment)
        guard (try? runner.start()) != nil else { return nil }
        let result = runner.waitUntilExit()
        return result.lines.first { !$0.isEmpty }
    }
}
