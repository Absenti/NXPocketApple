import Foundation
import NXPocketKit

/// The steps the launcher can do itself. Each writes only into its own folder (`SetupPaths`), runs nothing with sudo,
/// checks every download against its pin before using it, and can be run again after a failure: what an earlier try
/// left half-made is replaced, what it finished is kept.
extension FirstRunSetup {
    // MARK: - Python

    /// Python 3.14 from python-build-standalone, a virtual environment from it at `SetupPaths.venv` (where the
    /// launcher looks first), and the pinned packages, hashes checked. Returns the environment's Python.
    @discardableResult
    public static func installPython(paths: SetupPaths = .standard, appleSilicon: Bool = isAppleSilicon,
                                     progress: @escaping Progress, log: @escaping Log) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let environment = SetupCommand.environment(xcode: nil)

        if !runs(paths.pythonExecutable, environment: environment) {
            let download = SetupPins.python(arm64: appleSilicon)
            let archive = paths.downloads.appendingPathComponent("python.tar.gz")
            progress(0, "downloading Python \(SetupPins.pythonVersion)")
            try SetupDownload.fetch(download, to: archive) { written, expected in
                let total = expected > 0 ? expected : download.size
                progress(0.6 * Double(written) / Double(max(total, 1)),
                         "downloading Python \(SetupPins.pythonVersion): \(megabytes(written)) of \(megabytes(total))")
            }
            log("setup: Python \(SetupPins.pythonVersion) downloaded, SHA-256 matches its pin")
            progress(0.62, "unpacking Python")
            let partial = paths.root.appendingPathComponent(".python-partial-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: partial) }
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
            try SetupCommand(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", partial.path],
                             directory: nil, environment: environment).run()
            try? fileManager.removeItem(at: archive)
            let unpacked = partial.appendingPathComponent("python", isDirectory: true)
            guard runs(unpacked.appendingPathComponent("bin/python3"), environment: environment) else {
                throw NXPocketError(.engineFailed, "the Python archive did not unpack into a Python that runs")
            }
            try? fileManager.removeItem(at: paths.pythonBase)
            try fileManager.moveItem(at: unpacked, to: paths.pythonBase)
        }

        // A virtual environment points at its base Python by path: one made from another Python (tools/setup_python.sh
        // takes Homebrew's) or one that no longer starts is made again. It holds only packages, nothing of the user's.
        progress(0.66, "making the launcher's Python environment")
        if fileManager.fileExists(atPath: paths.venv.path),
           venvHome(paths.venv) != paths.pythonBase.appendingPathComponent("bin").path
            || !runs(paths.venvPython, environment: environment) {
            log("setup: replacing the Python environment at \(paths.venv.path), made from another Python")
            try fileManager.removeItem(at: paths.venv)
        }
        if !fileManager.fileExists(atPath: paths.venv.path) {
            try SetupCommand(executable: paths.pythonExecutable, arguments: ["-m", "venv", paths.venv.path],
                             directory: nil, environment: environment).run()
        }

        progress(0.7, "installing the engine's packages")
        let requirements = paths.root.appendingPathComponent(".python-requirements.txt")
        try Data((SetupPins.pythonRequirements + "\n").utf8).write(to: requirements)
        defer { try? fileManager.removeItem(at: requirements) }
        var collected = 0
        let expected = SetupPins.pythonRequirements.split(separator: "\n").filter { $0.contains("==") }.count
        try SetupCommand(executable: paths.venvPython,
                         arguments: ["-m", "pip", "install", "--require-hashes", "--only-binary", ":all:", "-r", requirements.path],
                         directory: nil, environment: environment).run { line in
            log("pip: \(line)")
            if line.hasPrefix("Collecting") {
                collected += 1
                progress(0.7 + 0.25 * min(1, Double(collected) / Double(max(expected, 1))), line)
            }
        }

        progress(0.97, "checking the environment")
        guard let found = PythonEnvironment.inspect(paths.venvPython), found.isComplete else {
            let missing = PythonEnvironment.inspect(paths.venvPython)?.missing.joined(separator: ", ") ?? "it does not start"
            throw NXPocketError(.engineFailed, "the Python environment is incomplete (\(missing))")
        }
        log("setup: Python environment ready at \(paths.venvPython.path)")
        progress(1, "ready")
        return paths.venvPython
    }

    /// `home = …` of a virtual environment's `pyvenv.cfg`: the folder of the Python it was made from.
    static func venvHome(_ venv: URL) -> String? {
        guard let data = try? BoundedRead.data(at: venv.appendingPathComponent("pyvenv.cfg"), limit: 64 << 10),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "home" { return parts[1] }
        }
        return nil
    }

    static func runs(_ python: URL, environment: [String: String]) -> Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && quick(python, ["-I", "-c", "import sys"], environment)?.status == 0
    }

    // MARK: - XcodeGen

    @discardableResult
    public static func installXcodeGen(paths: SetupPaths = .standard, progress: @escaping Progress,
                                       log: @escaping Log) throws -> URL {
        let fileManager = FileManager.default
        let environment = SetupCommand.environment(xcode: nil)
        if xcodegenVersion(paths.xcodegen, environment: environment) == SetupPins.xcodegenVersion { return paths.xcodegen }
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let archive = paths.downloads.appendingPathComponent("xcodegen.zip")
        progress(0, "downloading XcodeGen \(SetupPins.xcodegenVersion)")
        try SetupDownload.fetch(SetupPins.xcodegen, to: archive) { written, expected in
            let total = expected > 0 ? expected : SetupPins.xcodegen.size
            progress(0.8 * Double(written) / Double(max(total, 1)), "downloading XcodeGen: \(megabytes(written)) of \(megabytes(total))")
        }
        log("setup: XcodeGen \(SetupPins.xcodegenVersion) downloaded, SHA-256 matches its pin")
        progress(0.85, "unpacking XcodeGen")
        let partial = paths.root.appendingPathComponent(".xcodegen-partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: partial) }
        try SetupCommand(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, partial.path],
                         directory: nil, environment: environment).run()
        try? fileManager.removeItem(at: archive)
        let binary = partial.appendingPathComponent("xcodegen/bin/xcodegen")
        guard xcodegenVersion(binary, environment: environment) == SetupPins.xcodegenVersion else {
            throw NXPocketError(.engineFailed, "the XcodeGen archive did not unpack into XcodeGen \(SetupPins.xcodegenVersion)")
        }
        try? fileManager.removeItem(at: paths.xcodegenFolder)
        try fileManager.moveItem(at: partial, to: paths.xcodegenFolder)
        log("setup: XcodeGen ready at \(paths.xcodegen.path)")
        progress(1, "ready")
        return paths.xcodegen
    }

    /// "2.46.0" from `xcodegen --version` ("Version: 2.46.0"), nil when it does not run.
    static func xcodegenVersion(_ binary: URL, environment: [String: String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              let line = firstLine(quick(binary, ["--version"], environment)) else { return nil }
        return line.replacingOccurrences(of: "Version:", with: "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The engine

    /// NX2Apple at its pinned commit in the launcher's folder, then its own `tools/engine.py sync`, which fetches
    /// nxnative at NX2Apple's pin and applies NX2Apple's patches into `<checkout>/engine`. Only called when the
    /// launcher has no engine: an engine tree that is already there is never touched.
    ///
    /// `python` runs engine.py (3.9 or later, standard library only). `repository` is this project's checkout, when
    /// the launcher runs from one: its own patches (`patches/series`) are applied too, when it lists any.
    @discardableResult
    public static func installEngine(paths: SetupPaths = .standard, python: URL, xcode: URL?, repository: URL?,
                                     progress: @escaping Progress, log: @escaping Log) throws -> URL {
        let fileManager = FileManager.default
        let environment = SetupCommand.environment(xcode: xcode)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let revision = SetupPins.nx2appleRevision
        func run(_ arguments: [String], in directory: URL? = nil) throws {
            try SetupCommand(executable: git, arguments: arguments, directory: directory, environment: environment)
                .run { log("git: \($0)") }
        }
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)

        progress(0.02, "fetching NX2Apple at \(revision.prefix(8))")
        if fileManager.fileExists(atPath: paths.checkout.appendingPathComponent(".git").path) {
            let head = firstLine(quick(git, ["-C", paths.checkout.path, "rev-parse", "HEAD"], environment))
            if head != revision {
                try run(["-C", paths.checkout.path, "fetch", "--depth", "1", "origin", revision])
                try run(["-C", paths.checkout.path, "checkout", "-q", "--detach", "FETCH_HEAD"])
            }
        } else {
            if fileManager.fileExists(atPath: paths.checkout.path) {
                // Something that is not a checkout sits where the clone goes: kept aside rather than deleted.
                let aside = paths.root.appendingPathComponent("NX2Apple.left-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
                try fileManager.moveItem(at: paths.checkout, to: aside)
                log("setup: \(paths.checkout.lastPathComponent) was not a git checkout, moved to \(aside.lastPathComponent)")
            }
            // Cloned beside its place and moved there once checked out: an interrupted clone is never taken for one.
            let partial = paths.root.appendingPathComponent(".NX2Apple-partial-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: partial) }
            try run(["init", "-q", partial.path])
            try run(["-C", partial.path, "remote", "add", "origin", SetupPins.nx2appleRepository])
            try run(["-C", partial.path, "fetch", "--depth", "1", "origin", revision])
            try run(["-C", partial.path, "checkout", "-q", "--detach", "FETCH_HEAD"])
            try fileManager.moveItem(at: partial, to: paths.checkout)
        }
        let head = firstLine(quick(git, ["-C", paths.checkout.path, "rev-parse", "HEAD"], environment))
        guard head == revision else {
            throw NXPocketError(.engineFailed, "the NX2Apple checkout is at \(head ?? "?"), not at the pinned \(revision)")
        }
        log("setup: NX2Apple at \(revision)")

        progress(0.2, "building the engine tree (nxnative and its patches)")
        try SetupCommand(executable: python, arguments: ["tools/engine.py", "sync"], directory: paths.checkout,
                         environment: environment).run { line in
            log("engine.py: \(line)")
            progress(nil, line)
        }
        guard EngineLocation(root: paths.engine).isUsable else {
            throw NXPocketError(.engineFailed, "engine.py sync finished without an engine tree in \(paths.engine.path)")
        }
        guard engineKey(paths.engine) == SetupPins.engineKey else {
            throw NXPocketError(.engineFailed, "the engine built is not the pinned one (its stamp says \(engineKey(paths.engine) ?? "nothing"))")
        }

        if let repository, !projectPatches(in: repository).isEmpty {
            progress(0.95, "applying this project's engine patches")
            var patchEnvironment = environment
            patchEnvironment["NXPOCKET_ENGINE"] = paths.engine.path
            try SetupCommand(executable: URL(fileURLWithPath: "/bin/bash"),
                             arguments: [repository.appendingPathComponent("tools/apply_patches.sh").path],
                             directory: repository, environment: patchEnvironment).run { log("patches: \($0)") }
        }
        log("setup: engine ready at \(paths.engine.path)")
        progress(1, "ready")
        return paths.engine
    }

    /// The `key` line of the stamp engine.py writes into `engine/.git`.
    static func engineKey(_ engine: URL) -> String? {
        guard let data = try? BoundedRead.data(at: engine.appendingPathComponent(".git/nx2apple-stamp"), limit: 64 << 10),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("key ") }.map { String($0.dropFirst(4)) }
    }

    /// The patch names `patches/series` lists (a `#` starts a comment).
    static func projectPatches(in repository: URL) -> [String] {
        guard let data = try? BoundedRead.data(at: repository.appendingPathComponent("patches/series"), limit: 1 << 20),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let name = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
    }

    // MARK: - Xcode's Metal compiler

    /// Apple's own download of the Metal toolchain, a component Xcode 26 and later fetch apart. No sudo: the system's
    /// asset service installs it.
    public static func downloadMetalToolchain(xcode: URL, progress: @escaping Progress, log: @escaping Log) throws {
        progress(nil, "downloading the Metal toolchain (xcodebuild)")
        try SetupCommand(executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                         arguments: ["-downloadComponent", "metaltoolchain"],
                         directory: nil, environment: SetupCommand.environment(xcode: xcode)).run { line in
            log("xcodebuild: \(line)")
            progress(percent(in: line).map { $0 / 100 }, line)
        }
        progress(1, "ready")
    }

    /// The last "12.5%" of a line of progress, as 12.5.
    static func percent(in line: String) -> Double? {
        // A regular expression search does not run backwards: every match is read, the last one kept.
        var last: Double?
        var rest = line[...]
        while let range = rest.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression) {
            last = Double(rest[range].dropLast())
            rest = rest[range.upperBound...]
        }
        return last
    }
}
