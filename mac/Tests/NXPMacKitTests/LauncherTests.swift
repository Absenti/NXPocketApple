import Foundation
import NXPocketKit
import XCTest

@testable import NXPMacKit
@testable import NXPMacModel

/// The launcher's own tests. They cover what can be decided without a game, an iPhone or the engine: the argument
/// list handed to the engine, its event stream, what it left behind, and the package the launcher writes.
final class EngineBuilderTests: XCTestCase {
    private func builder() -> EngineBuilder {
        var toolchain = Toolchain.empty
        toolchain.engine = EngineLocation(root: URL(fileURLWithPath: "/tmp/engine"))
        toolchain.python = URL(fileURLWithPath: "/usr/bin/python3")
        return EngineBuilder(toolchain: toolchain)
    }

    func testArgumentsAskForTheFrameworkOnly() {
        let request = EngineBuildRequest(gameFolder: URL(fileURLWithPath: "/games/Zelda"),
                                         keysFile: URL(fileURLWithPath: "/Users/me/prod.keys"),
                                         stagingFolder: URL(fileURLWithPath: "/tmp/staging"))
        let arguments = builder().arguments(request)
        XCTAssertTrue(arguments.contains("--shell-framework"))
        XCTAssertTrue(arguments.contains("--romfs"))
        XCTAssertTrue(arguments.contains("separate"))
        XCTAssertTrue(arguments.contains("--progress"))
        XCTAssertTrue(arguments.contains("json"))
        XCTAssertTrue(arguments.contains("--keep-extracted"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-k")! + 1], "/Users/me/prod.keys")
        XCTAssertEqual(arguments[0], "/tmp/engine/scripts/build_ipa_from_nsp.py")
    }

    func testArgumentsCarryTheOptionalSwitches() {
        let request = EngineBuildRequest(gameFolder: URL(fileURLWithPath: "/games/Zelda"),
                                         titleID: "0100111000200000",
                                         language: "fr",
                                         keepExtracted: false,
                                         allowOtherMetal: true,
                                         stagingFolder: URL(fileURLWithPath: "/tmp/staging"),
                                         workFolder: URL(fileURLWithPath: "/tmp/work"))
        let arguments = builder().arguments(request)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--title-id")! + 1], "0100111000200000")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-l")! + 1], "fr")
        XCTAssertTrue(arguments.contains("--no-keep-extracted"))
        XCTAssertTrue(arguments.contains("--allow-other-metal"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--work-dir")! + 1], "/tmp/work")
        XCTAssertFalse(arguments.contains("--keep-extracted"))
    }

    func testParsesTheEnginesStageEvents() {
        let line = #"{"ev":"stage","k":3,"n":9,"name":"unpack","step":"","t":1.0}"#
        guard case .stage(let index, let count, let name, let step) = EngineEventParser.parse(line: line) else {
            return XCTFail("not a stage")
        }
        XCTAssertEqual(index, 3)
        XCTAssertEqual(count, 9)
        XCTAssertEqual(name, "unpack")
        XCTAssertEqual(step, "")

        let stepLine = #"{"ev":"step","k":7,"name":"shaders","step":"compiling","t":2.0}"#
        guard case .step(let stage, let stepName) = EngineEventParser.parse(line: stepLine) else { return XCTFail("not a step") }
        XCTAssertEqual(stage, "shaders")
        XCTAssertEqual(stepName, "compiling")
    }

    func testParsesProgressAndEnd() {
        // A real line of the engine's shader stage: the step is a name.
        let progress = #"{"ev":"progress","k":7,"name":"shaders","step":"compiling","done":120,"total":300,"unit":"shaders","est":false,"note":"464 not cached","frac":0.4,"eta":12.5,"elapsed":3.0,"t":5.0}"#
        guard case .progress(let name, let step, let done, let total, let unit, let note, let fraction, let eta, _)
                = EngineEventParser.parse(line: progress) else { return XCTFail("not progress") }
        XCTAssertEqual(name, "shaders")
        XCTAssertEqual(step, "compiling")
        XCTAssertEqual(done, 120)
        XCTAssertEqual(total, 300)
        XCTAssertEqual(unit, "shaders")
        XCTAssertEqual(note, "464 not cached")
        XCTAssertEqual(fraction ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(eta ?? 0, 12.5, accuracy: 0.0001)

        let end = #"{"ev":"stage_end","k":1,"name":"extract","ok":true,"summary":"done","elapsed":9.5,"warn":true}"#
        guard case .stageEnd(let index, _, let ok, let summary, let warn) = EngineEventParser.parse(line: end) else {
            return XCTFail("not stage_end")
        }
        XCTAssertEqual(index, 1)
        XCTAssertTrue(ok)
        XCTAssertEqual(summary, "done")
        XCTAssertTrue(warn)
    }

    /// The bug the build screen had: every stage after one that reached 0.99 stayed at 0%.
    func testEveryStageMovesItsOwnBar() {
        var progress = BuildProgress()
        let lines = [
            #"{"ev":"stage","k":2,"n":9,"name":"extract","step":""}"#,
            #"{"ev":"progress","k":2,"name":"extract","step":"","done":990,"total":1000,"unit":"files","frac":0.99}"#,
            #"{"ev":"stage","k":7,"n":9,"name":"shaders","step":""}"#,
            #"{"ev":"step","k":7,"name":"shaders","step":"compiling"}"#,
        ]
        for line in lines { progress.apply(EngineEventParser.parse(line: line)) }
        XCTAssertEqual(progress.stage, "7/9 · shaders")
        XCTAssertEqual(progress.fraction, 0, "a new stage starts its bar from zero")
        XCTAssertEqual(progress.detail, "compiling")

        let compiling = #"{"ev":"progress","k":7,"name":"shaders","step":"compiling","done":120,"total":300,"unit":"shaders","note":"464 not cached","frac":0.4}"#
        XCTAssertTrue(progress.apply(EngineEventParser.parse(line: compiling)))
        XCTAssertEqual(progress.fraction, 0.4, accuracy: 0.0001, "below the previous stage's 0.99, and still shown")
        XCTAssertEqual(progress.detail, "compiling · 120 / 300 shaders · 464 not cached")

        XCTAssertFalse(progress.apply(.message("a line for the log")), "only stage, step and progress move the bar")
    }

    func testAByteCountReadsAsSizes() {
        let detail = BuildProgress.detail(step: "RomFS", done: 1_048_576, total: nil, unit: "B", note: nil)
        XCTAssertTrue(detail.hasPrefix("RomFS · "), detail)
        XCTAssertFalse(detail.contains("1048576"), "bytes are shown as a size: \(detail)")
    }

    func testAPlainLineStaysPlain() {
        guard case .raw(let line) = EngineEventParser.parse(line: "warning: shader regressed") else { return XCTFail("not raw") }
        XCTAssertEqual(line, "warning: shader regressed")
    }

    func testFindsWhatTheEngineLeft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        let work = root.appendingPathComponent("0100111000200000_build")
        let extract = work.appendingPathComponent("extract/v65536")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("DmGame0100111000200000.framework"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("aoc"), withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "schema": 1, "title_id": "0100111000200000", "name": "Left", "display_version": "1.0", "package_version": "v65536",
            "modules": ["main"], "nro_count": 0, "chain": "b-1", "loader": "FR", "framework": "DmGame0100111000200000.framework",
            "framework_executable": "DmGame", "image_marker": "m", "profile": "profile.tsv", "shader_map": "dm/shader_map.tsv",
            "launcher": "dm/launcher.json", "romfs_marker": "x", "romfs_identity": "DMROMFSID1 x", "min_os": "26.0"]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: staging.appendingPathComponent("DmGame0100111000200000.framework/\(GameManifest.fileName)"))
        let image = extract.appendingPathComponent("RomFS.img")
        try Data(repeating: 0, count: 64).write(to: image)
        // An older version's image, written later: the newest file is not the one built.
        let other = work.appendingPathComponent("extract/v0")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: other.appendingPathComponent("RomFS.img"))

        let framework = try XCTUnwrap(EngineBuilder.framework(in: staging))
        XCTAssertEqual(framework.lastPathComponent, "DmGame0100111000200000.framework")
        let request = EngineBuildRequest(gameFolder: work.appendingPathComponent("inputs"), stagingFolder: staging,
                                         workFolder: work, includesDLC: true)
        let output = try builder().outputs(for: request, reportedRomfs: image)
        XCTAssertEqual(output.romfsImage, image, "the image the engine named, not the newest one")
        XCTAssertEqual(output.aocFolder?.lastPathComponent, "aoc")
        XCTAssertThrowsError(try builder().outputs(for: request, reportedRomfs: nil),
                             "without the engine's game files line nothing is guessed")
        XCTAssertThrowsError(try builder().outputs(for: request, reportedRomfs: work.appendingPathComponent("gone.img")))
        // When the engine's line cannot be read the image of the very version built is taken, from its fixed place,
        // never the newest one found (v0 here was written later).
        var versioned = request
        versioned.expectedVersion = 65536
        XCTAssertEqual(try builder().outputs(for: versioned, reportedRomfs: nil).romfsImage, image)
        versioned.expectedVersion = 7
        XCTAssertThrowsError(try builder().outputs(for: versioned, reportedRomfs: nil), "no image for that version: nothing is guessed")
        // The engine's extract_aoc writes <build folder>/aoc, beside extract/, not inside a version's folder: the
        // launcher looked inside the version's folder and never packed a DLC.
        XCTAssertEqual(EngineBuilder.addOnFolder(romfsImage: image, workFolder: nil)?.resolvingSymlinksInPath().path,
                       work.appendingPathComponent("aoc").resolvingSymlinksInPath().path)
        XCTAssertEqual(EngineBuilder.addOnFolder(romfsImage: nil, workFolder: work)?.lastPathComponent, "aoc")
    }

    /// What broke every build since 0.2.0, after the whole build: the engine's `say` puts the time before each message
    /// (`[21:05:47] game files: …`, measured on the engine this launcher syncs), and the launcher looked for the words
    /// at the start of the line. The Mario Kart build ended in "the engine did not name the game's RomFS image".
    func testTheEnginesLinesAreReadWithTheClockItPutsBeforeThem() {
        let line = "[23:23:26] game files: /g/0100_build/extract/v1441792/RomFS.img"
        XCTAssertEqual(EngineBuilder.romfsImage(inMessage: line)?.path, "/g/0100_build/extract/v1441792/RomFS.img")
        XCTAssertEqual(EngineBuilder.romfsImage(inMessage: "  [01:02:03]   game files: /a b/RomFS.img  ")?.path, "/a b/RomFS.img")
        XCTAssertNil(EngineBuilder.romfsImage(inMessage: "[23:23:18] game files: separate (DM_COPY_ROMFS=NO), left out of the app; the image stays at /g/RomFS.img"),
                     "the engine's other line starting with the same words names no image")
        XCTAssertNil(EngineBuilder.romfsImage(inMessage: "[23:23:26] game framework: /tmp/x/DmGame.framework"))
        XCTAssertEqual(EngineBuilder.withoutClock("[21:05:47] app: Mario Kart 8 Deluxe"), "app: Mario Kart 8 Deluxe")
        XCTAssertEqual(EngineBuilder.withoutClock("[RED] not a clock"), "[RED] not a clock")
        XCTAssertEqual(EngineBuilder.withoutClock("[1:2:3] too short to be one"), "[1:2:3] too short to be one")
        XCTAssertEqual(EngineBuilder.withoutClock("[ab:cd:ef] letters"), "[ab:cd:ef] letters")
        XCTAssertEqual(EngineBuilder.withoutClock("no clock at all"), "no clock at all")
    }

    func testTheEnginesGameFilesLineNamesTheImageBuilt() {
        XCTAssertEqual(EngineBuilder.romfsImage(inMessage: "game files: /g/0100_build/extract/v0/RomFS.img")?.path,
                       "/g/0100_build/extract/v0/RomFS.img")
        XCTAssertNil(EngineBuilder.romfsImage(inMessage: "game files: /g/0100_build/extract/v0/RomFS"), "a folder is not an image")
        XCTAssertNil(EngineBuilder.romfsImage(inMessage: "game framework: /tmp/x"))
    }

    func testAPackageVersionGoesToTheEngineOnlyWhenSet() {
        let folder = URL(fileURLWithPath: "/games/A_build/inputs")
        let staging = URL(fileURLWithPath: "/tmp/staging")
        let with = builder().arguments(EngineBuildRequest(gameFolder: folder, packageVersion: "v0", stagingFolder: staging))
        XCTAssertEqual(with[with.firstIndex(of: "--package")! + 1], "v0")
        XCTAssertFalse(builder().arguments(EngineBuildRequest(gameFolder: folder, stagingFolder: staging)).contains("--package"))
    }
}

final class DeviceInventoryTests: XCTestCase {
    /// The fixture above is hand-written, so it can lie. This runs the real tool and parses its real output, so a
    /// change in devicectl's JSON shape is caught here rather than on someone's desk.
    func testParsesTheRealToolOutput() throws {
        var toolchain = Toolchain.empty
        guard FileManager.default.isExecutableFile(atPath: toolchain.xcrun.path) else {
            throw XCTSkip("no xcrun on this machine")
        }
        toolchain.xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let devices: [Device]
        do {
            devices = try DeviceInventory.list(toolchain: toolchain)
        } catch let error as NXPocketError where error.code == .deviceUnavailable {
            throw XCTSkip("devicectl is unavailable here: \(error.detail)")
        }
        // On a Mac with Xcode set up, devicectl reports at least its simulators; a CI runner can report none, and then
        // there is nothing to check. Every entry must come back with the fields the launcher needs.
        guard !devices.isEmpty else { throw XCTSkip("devicectl lists no device on this machine") }
        for device in devices {
            XCTAssertFalse(device.udid.isEmpty, "a device came back with no UDID")
            XCTAssertFalse(device.name.isEmpty, "\(device.udid) came back with no name")
            XCTAssertFalse(device.model.isEmpty, "\(device.udid) came back with no model")
        }
        XCTAssertTrue(devices.contains { $0.isSimulator } || devices.contains { $0.isPhysical },
                      "no device's reality was recognised")
    }

    func testReadsDevicectlsJSON() throws {
        let json = """
        {"result":{"devices":[
          {"identifier":"SIM-1","properties":{"hardware":{"udid":"SIM-1","reality":"simulated","marketingName":"iPhone 17","productType":"iPhone18,3"},
            "connection":{"pairingState":"paired","state":"disconnected","transportType":"sameMachine"},"device":{"name":"iPhone 17"}}},
          {"identifier":"PHY-1","properties":{"hardware":{"udid":"PHY-1","reality":"physical","marketingName":"iPhone 15 Pro","productType":"iPhone16,1"},
            "connection":{"pairingState":"paired","state":"connected","transportType":"wired"},"device":{"name":"iPhone de Example","osVersionNumber":"27.0.1"}}}]}}
        """
        let devices = try DeviceInventory.parse(json: Data(json.utf8))
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first?.udid, "PHY-1", "a physical device sorts first")
        XCTAssertEqual(devices.first?.model, "iPhone 15 Pro")
        XCTAssertEqual(devices.first?.osVersion, "27.0.1")
        XCTAssertTrue(devices.first?.canReceive ?? false)
        XCTAssertEqual(devices.last?.isSimulator, true)
        XCTAssertFalse(devices.last?.canReceive ?? true)
    }

    func testRefusesSomethingElse() {
        XCTAssertThrowsError(try DeviceInventory.parse(json: Data("{}".utf8))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .deviceUnavailable)
        }
    }

    func testSendsTheFrameworkBeforeTheRomfsAndSkipsOnlyTheFindersFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-top-\(UUID().uuidString)")
        let package = root.appendingPathComponent("0100111000200000.nxgame", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("DmGame.framework"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 32).write(to: package.appendingPathComponent("package.json"))
        try Data(repeating: 0, count: 4096).write(to: package.appendingPathComponent("romfs.img"))
        try Data(repeating: 0, count: 6148).write(to: package.appendingPathComponent(".DS_Store"))
        defer { try? FileManager.default.removeItem(at: root) }

        let transfer = DeviceTransfer(toolchain: .empty)
        let entries = try transfer.topLevel(of: package)
        XCTAssertEqual(entries.map(\.name), ["DmGame.framework", "package.json", "romfs.img"])
        XCTAssertEqual(entries.last?.size, 4096)
    }
}

final class LocalLibraryTests: XCTestCase {
    func testListsPackagesAndTheirProblems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("0100111000200000.nxgame"), withIntermediateDirectories: true)
        try "{ not json }".write(to: root.appendingPathComponent("0100111000200000.nxgame/package.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("half-written"), withIntermediateDirectories: true)

        let games = LocalLibrary.scan(outputFolder: root)
        XCTAssertEqual(games.count, 1, "a folder without the extension is not a package")
        XCTAssertEqual(games.first?.id, "0100111000200000")
        XCTAssertEqual(games.first?.problem?.code, .packageDamaged)
    }

    func testChoosesTheDestinationFolderName() {
        let folder = URL(fileURLWithPath: "/Users/me/Documents/NXPocket")
        XCTAssertEqual(LocalLibrary.destination(for: TitleID("0100111000200000")!, in: folder).lastPathComponent,
                       "0100111000200000.nxgame")
    }
}

final class SettingsStoreTests: XCTestCase {
    @MainActor
    func testPersistsAndReloads() {
        let defaults = UserDefaults(suiteName: "dev.nxpocket.tests.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.value.keysFile = "/Users/me/prod.keys"
        store.value.bundleID = "dev.nxpocket.other"

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.value.keysFile, "/Users/me/prod.keys")
        XCTAssertEqual(reloaded.value.bundleID, "dev.nxpocket.other")
    }

    func testDefaultsToTheDocumentedFolders() {
        let settings = LauncherSettings()
        XCTAssertEqual(settings.bundleID, "dev.nxpocketapple.app")
        XCTAssertEqual(settings.outputURL.lastPathComponent, "NXPocket")
        XCTAssertNil(settings.keysURL)
    }
}

final class ToolchainTests: XCTestCase {
    func testEngineLayoutDerivesItsPaths() {
        let engine = EngineLocation(root: URL(fileURLWithPath: "/repo/engine"))
        XCTAssertEqual(engine.buildScript.path, "/repo/engine/scripts/build_ipa_from_nsp.py")
        XCTAssertEqual(engine.romfsTool.path, "/repo/engine/dm/tools/romfs_image.py")
        XCTAssertFalse(engine.isUsable)
    }

    func testFindsAPythonThatIsNewEnough() {
        let python = ToolchainLocator.python(preferred: nil)
        if let version = ToolchainLocator.pythonVersion(at: python) {
            XCTAssertGreaterThanOrEqual(version.0, 3)
            XCTAssertGreaterThanOrEqual(version.1, 10)
        }
    }

    func testSavedSettingsWithThePreRenameBundleIDMoveToTheNewOne() throws {
        let old = Data(#"{"bundleID": "dev.nxpocket.app", "gameFolder": "/games"}"#.utf8)
        let decoded = try JSONDecoder().decode(LauncherSettings.self, from: old)
        XCTAssertEqual(decoded.bundleID, "dev.nxpocketapple.app")
        XCTAssertEqual(decoded.gameFolder, "/games", "the other settings are kept")
        let custom = Data(#"{"bundleID": "dev.nxpocket.other"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LauncherSettings.self, from: custom).bundleID, "dev.nxpocket.other",
                       "an identifier the user typed is left alone")
    }
}
