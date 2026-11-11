import Foundation
import XCTest

import NXPocketKit
@testable import NXPMacKit

/// The first-run setup: what it pins, what it reports missing and in which order, and what it refuses.
final class SetupTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Pins

    func testTheLaunchersPythonRequirementsAreTheToolsFileWordForWord() throws {
        let file = try String(contentsOf: repository.appendingPathComponent("tools/python-requirements.txt"), encoding: .utf8)
        XCTAssertEqual(SetupPins.pythonRequirements.trimmingCharacters(in: .whitespacesAndNewlines),
                       file.trimmingCharacters(in: .whitespacesAndNewlines),
                       "tools/setup_python.sh and the Setup screen must install the same versions")
    }

    func testEveryRequirementIsAnExactVersionWithItsHashes() {
        var current: String?
        var hashes: [String: Int] = [:]
        for raw in SetupPins.pythonRequirements.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("--hash=sha256:") {
                let hash = line.dropFirst("--hash=sha256:".count).replacingOccurrences(of: " \\", with: "")
                XCTAssertEqual(hash.count, 64, line)
                XCTAssertTrue(hash.allSatisfy(\.isHexDigit), line)
                if let current { hashes[current, default: 0] += 1 }
            } else {
                XCTAssertTrue(line.contains("=="), "\(line) is not an exact version")
                current = String(line.split(separator: " ").first ?? "")
            }
        }
        for name in ["lz4", "capstone", "fonttools", "zbic", "nsz", "pycryptodome", "zstandard"] {
            let key = hashes.keys.first { $0.hasPrefix(name + "==") }
            XCTAssertNotNil(key, "\(name) is pinned")
            XCTAssertGreaterThan(hashes[key ?? ""] ?? 0, 0, "\(name) has hashes")
        }
    }

    func testDownloadsArePinnedToFullHashesAndTheEngineToACommit() {
        for download in [SetupPins.python(arm64: true), SetupPins.python(arm64: false), SetupPins.xcodegen] {
            XCTAssertEqual(download.url.scheme, "https")
            XCTAssertEqual(download.url.host, "github.com")
            XCTAssertEqual(download.sha256.count, 64)
            XCTAssertGreaterThan(download.size, 1_000_000)
        }
        XCTAssertNotEqual(SetupPins.python(arm64: true).sha256, SetupPins.python(arm64: false).sha256)
        XCTAssertEqual(SetupPins.nx2appleRevision.count, 40)
        XCTAssertEqual(SetupPins.engineKey.count, 64)
    }

    func testTheLauncherLooksWhereTheSetupInstalls() {
        let paths = SetupPaths.standard
        XCTAssertEqual(ToolchainLocator.ownEnvironment, paths.venvPython)
        XCTAssertTrue(PhoneAppBuild.toolFolders.contains(paths.xcodegenBin.path))
        XCTAssertTrue(paths.engine.path.hasSuffix("Library/Application Support/NXPocket/NX2Apple/engine"))
    }

    // MARK: - What is missing, in order

    func testOnlyTheCommandLineToolsSendsToTheAppStoreAndHoldsTheRest() {
        var facts = SetupFacts()
        facts.commandLineToolsOnly = true
        facts.pythonMissing = ["Python 3.12 or later"]
        let states = FirstRunSetup.states(facts)
        guard case .missing(let text)? = states[.xcode] else { return XCTFail("\(String(describing: states[.xcode]))") }
        XCTAssertTrue(text.contains("Command Line Tools"), text)
        for step in [SetupStep.xcodeReady, .iosSDK, .metalToolchain, .engine] {
            guard case .waiting? = states[step] else { return XCTFail("\(step): \(String(describing: states[step]))") }
        }
        guard case .missing? = states[.python] else { return XCTFail("Python does not need Xcode") }
        guard case .missing? = states[.xcodegen] else { return XCTFail("XcodeGen does not need Xcode") }
    }

    func testXcodeBeforeItsFirstStartHoldsTheEngine() {
        var facts = SetupFacts()
        facts.xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        facts.licenceAccepted = true
        facts.firstLaunchDone = false
        let states = FirstRunSetup.states(facts)
        guard case .missing(let text)? = states[.xcodeReady] else { return XCTFail() }
        XCTAssertTrue(text.contains("first start"), text)
        guard case .waiting? = states[.engine] else { return XCTFail("the engine is fetched with Xcode's git") }
    }

    func testAMacWithEverythingIsReady() {
        var facts = SetupFacts()
        facts.xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        facts.xcodeVersion = "27.2"
        facts.licenceAccepted = true
        facts.firstLaunchDone = true
        facts.iosSDK = "27.2"
        facts.metal = "Apple metal version 32023.922"
        facts.python = "/x/venv/bin/python3"
        facts.engine = URL(fileURLWithPath: "/x/engine")
        facts.xcodegen = URL(fileURLWithPath: "/x/xcodegen")
        let states = FirstRunSetup.states(facts)
        for step in SetupStep.allCases {
            XCTAssertTrue(states[step]?.isReady == true, "\(step): \(String(describing: states[step]))")
        }
    }

    func testAMissingMetalCompilerIsADownloadOfApplesOwn() {
        var facts = SetupFacts()
        facts.xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        facts.licenceAccepted = true
        facts.firstLaunchDone = true
        facts.iosSDK = "27.2"
        guard case .missing(let text)? = FirstRunSetup.states(facts)[.metalToolchain] else { return XCTFail() }
        XCTAssertTrue(text.contains("-downloadComponent metaltoolchain"), text)
    }

    // MARK: - What it refuses, and what it reads

    func testADownloadThatIsNotItsPinIsDeletedAndRefused() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-pin-\(UUID().uuidString)")
        try Data("not python".utf8).write(to: file)
        XCTAssertThrowsError(try SetupDownload.verify(file, against: SetupPins.python(arm64: true))) { error in
            XCTAssertTrue("\(error)".contains("not the pinned file"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "never left to be unpacked")
    }

    func testAMatchingFilePassesTheCheck() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("pinned".utf8)
        try data.write(to: file)
        let pin = SetupPins.Download(url: URL(string: "https://github.com/x")!,
                                     sha256: FileDigest.sha256(of: data), size: Int64(data.count))
        XCTAssertNoThrow(try SetupDownload.verify(file, against: pin))
    }

    func testTheVirtualEnvironmentsBasePythonIsRead() throws {
        let venv = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-venv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: venv) }
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        try Data("home = /opt/homebrew/opt/python@3.14/bin\ninclude-system-site-packages = false\n".utf8)
            .write(to: venv.appendingPathComponent("pyvenv.cfg"))
        XCTAssertEqual(FirstRunSetup.venvHome(venv), "/opt/homebrew/opt/python@3.14/bin")
    }

    func testTheEngineStampAndTheProjectsPatchSeriesAreRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("engine/.git"), withIntermediateDirectories: true)
        try Data("nx2apple-engine 1\npin abc\nkey \(SetupPins.engineKey)\nhead def\n".utf8)
            .write(to: root.appendingPathComponent("engine/.git/nx2apple-stamp"))
        XCTAssertEqual(FirstRunSetup.engineKey(root.appendingPathComponent("engine")), SetupPins.engineKey)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("patches"), withIntermediateDirectories: true)
        try Data("# comment\n\n0001-a.patch   # why\n  0002-b.patch\n".utf8).write(to: root.appendingPathComponent("patches/series"))
        XCTAssertEqual(FirstRunSetup.projectPatches(in: root), ["0001-a.patch", "0002-b.patch"])
        XCTAssertEqual(FirstRunSetup.projectPatches(in: repository), [], "the project's series lists no patch today")
    }

    func testProgressIsReadFromXcodebuildsLines() {
        XCTAssertEqual(FirstRunSetup.percent(in: "Downloading Metal Toolchain: 45.2% (310 MB of 687 MB)"), 45.2)
        XCTAssertEqual(FirstRunSetup.percent(in: "10% then 80%"), 80)
        XCTAssertNil(FirstRunSetup.percent(in: "Done."))
    }

    // MARK: - The real thing

    /// What the Setup screen would show on this Mac. Off by default: NXPOCKET_SETUP_LIVE=<anything> prints it.
    func testLiveStatesOfThisMac() throws {
        guard ProcessInfo.processInfo.environment["NXPOCKET_SETUP_LIVE"] != nil else {
            throw XCTSkip("set NXPOCKET_SETUP_LIVE to read this Mac")
        }
        let toolchain = ToolchainLocator.detect(engineRoot: nil)
        let states = FirstRunSetup.states(FirstRunSetup.gather(toolchain: toolchain))
        for step in SetupStep.allCases { print("this Mac: \(step.title): \(String(describing: states[step]!))") }
    }

    /// Downloads and installs Python, XcodeGen and the engine into a scratch folder, as the Setup screen does. Off by
    /// default (network, about 200 MB, a few minutes): NXPOCKET_SETUP_LIVE=<folder> runs it there.
    func testLiveInstallIntoAScratchFolder() throws {
        guard let folder = ProcessInfo.processInfo.environment["NXPOCKET_SETUP_LIVE"], !folder.isEmpty else {
            throw XCTSkip("set NXPOCKET_SETUP_LIVE to a scratch folder to download and install for real")
        }
        let paths = SetupPaths(root: URL(fileURLWithPath: folder, isDirectory: true))
        let lines = LockedLines()
        let started = Date()
        let python = try FirstRunSetup.installPython(paths: paths, progress: { _, _ in }, log: { lines.add($0) })
        XCTAssertTrue(PythonEnvironment.inspect(python)?.isComplete == true)
        let xcodegen = try FirstRunSetup.installXcodeGen(paths: paths, progress: { _, _ in }, log: { lines.add($0) })
        XCTAssertEqual(FirstRunSetup.xcodegenVersion(xcodegen, environment: SetupCommand.environment(xcode: nil)),
                       SetupPins.xcodegenVersion)
        let engine = try FirstRunSetup.installEngine(paths: paths, python: python,
                                                     xcode: ToolchainLocator.xcodeInstallations().first,
                                                     repository: repository, progress: { _, _ in }, log: { lines.add($0) })
        XCTAssertTrue(EngineLocation(root: engine).isUsable)
        XCTAssertEqual(FirstRunSetup.engineKey(engine), SetupPins.engineKey)
        // A second run finds everything in place and downloads nothing.
        let again = Date()
        _ = try FirstRunSetup.installPython(paths: paths, progress: { _, _ in }, log: { _ in })
        _ = try FirstRunSetup.installXcodeGen(paths: paths, progress: { _, _ in }, log: { _ in })
        _ = try FirstRunSetup.installEngine(paths: paths, python: python, xcode: ToolchainLocator.xcodeInstallations().first,
                                            repository: nil, progress: { _, _ in }, log: { _ in })
        print("live setup: first run \(Int(again.timeIntervalSince(started))) s, second run \(Int(Date().timeIntervalSince(again))) s")
        print(lines.all.filter { $0.hasPrefix("setup:") }.joined(separator: "\n"))
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
