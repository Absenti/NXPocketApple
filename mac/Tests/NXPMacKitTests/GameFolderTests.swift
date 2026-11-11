import Foundation
import NXPocketKit
import XCTest

@testable import NXPMacKit
@testable import NXPMacModel

/// The three launcher defects of 2026-11-10: a folder of several games could not be built (the engine wants
/// --title-id), an NSZ game failed because the chosen Python had no nsz, and Send named an app ID SideStore never
/// installs. Then the folder: read to its subfolders, and by the packages' contents, not their names only.
final class GameFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ data: Data = Data("x".utf8)) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func package(_ name: String, _ titles: [(UInt64, UInt32)], source: FolderPackage.Source = .contents,
                         bytes: Int64 = 100) -> FolderPackage {
        FolderPackage(url: root.appendingPathComponent(name), bytes: bytes,
                      titles: titles.map { PackageTitle(titleID: $0.0, kind: GameFolder.kind(of: $0.0), version: $0.1) },
                      source: source)
    }

    /// The user's folder: South Park's base game and update as NSZ, six DLC, and a SuperXCI holding Dragon Quest
    /// VII's base game, its update and six DLC in one file whose name carries no title ID.
    private func userFolder() -> GameFolderListing {
        var packages: [(package: FolderPackage, contents: PackageContents?)] = [
            (package("South Park [01008F2005154000][v0].nsz", [(0x01008F2005154000, 0)], bytes: 9_000), nil),
            (package("South Park [01008F2005154800][v327680].nsz", [(0x01008F2005154800, 327_680)], bytes: 4_000),
             PackageContents(titles: [], name: "South Park: TFBW", displayVersion: "1.05", icon: Data([0xFF, 0xD8]))),
            (package("South Park [DLC Danger Deck] [01008F2005155004][v0].nsp", [(0x01008F2005155004, 0)]), nil),
            (package("South Park [DLC Bring The Crunch] [01008F2005155006][v131072].nsp", [(0x01008F2005155006, 131_072)]), nil),
            (package("DRAGON QUEST VII Reimagined (v1.1.0 & DLC) (EU) SuperXCI-MBC.xci",
                     [(0x0100A9D01C446000, 0), (0x0100A9D01C446800, 65_536), (0x0100A9D01C447001, 0), (0x0100A9D01C447017, 0)],
                     bytes: 4_600),
             PackageContents(titles: [], name: "DRAGON QUEST VII Reimagined", displayVersion: "1.1.0")),
        ]
        for index in [1, 4] {
            let titles = packages[index].package.titles
            packages[index].contents?.titles = titles
        }
        return GameFolder.group(packages)
    }

    func testGroupsBaseUpdateAndDLCByApplicationWhereverTheyAre() {
        let listing = userFolder()
        XCTAssertEqual(listing.games.map(\.titleID), ["0100A9D01C446000", "01008F2005154000"], "sorted by name")
        let southPark = listing.games[1]
        XCTAssertEqual(southPark.name, "South Park: TFBW", "the newest control data names the game")
        XCTAssertEqual(southPark.displayVersion, "1.05")
        XCTAssertNotNil(southPark.icon)
        XCTAssertEqual(southPark.updates.map(\.version), [327_680])
        XCTAssertEqual(southPark.dlc.map(\.label), ["DLC Danger Deck", "DLC Bring The Crunch"])
        XCTAssertTrue(southPark.compressed)
        let dragonQuest = listing.games[0]
        XCTAssertTrue(dragonQuest.hasBase)
        XCTAssertEqual(dragonQuest.updates.count, 1)
        XCTAssertEqual(dragonQuest.dlc.map(\.label), ["DLC 1", "DLC 23"], "a merged file's DLC are named by their index")
        XCTAssertEqual(dragonQuest.packages.count, 1, "one file holds the whole game")
    }

    func testTheDefaultSelectionIsWhatTheEngineTookFromAWholeFolder() throws {
        let southPark = userFolder().games[1]
        let plan = try southPark.plan(.defaults(for: southPark))
        XCTAssertEqual(plan.version, 327_680)
        XCTAssertNil(plan.packageVersion, "the newest version given is the engine's own choice")
        XCTAssertEqual(plan.dlcTitleIDs, [0x01008F2005155004, 0x01008F2005155006])
        XCTAssertEqual(plan.inputs.count, 4)
        XCTAssertTrue(plan.compressed)
        XCTAssertEqual(plan.workFolder.lastPathComponent, "01008F2005154000_build")
        XCTAssertEqual(plan.inputFolder.deletingLastPathComponent(), plan.workFolder)
    }

    func testAnUntickedUpdateOrDLCIsLeftOutOfTheEnginesFolder() throws {
        let southPark = userFolder().games[1]
        let plan = try southPark.plan(GameSelection(updateID: nil, dlcIDs: [southPark.dlc[1].id]))
        XCTAssertEqual(plan.version, 0)
        XCTAssertNil(plan.packageVersion, "the update's file is not given, so v0 is all there is")
        XCTAssertEqual(plan.inputs.map(\.source.lastPathComponent),
                       ["South Park [01008F2005154000][v0].nsz", "South Park [DLC Bring The Crunch] [01008F2005155006][v131072].nsp"])
        XCTAssertEqual(plan.dlcTitleIDs, [0x01008F2005155006])
    }

    func testAMergedFilesUpdateIsLeftOutWithPackageAndItsDLCCannotBe() throws {
        let dragonQuest = userFolder().games[0]
        let selection = GameSelection(updateID: nil, dlcIDs: [])
        let plan = try dragonQuest.plan(selection)
        XCTAssertEqual(plan.packageVersion, "v0", "the update is in the base game's file: only --package leaves it out")
        XCTAssertEqual(plan.dlcTitleIDs.count, 2, "the engine packs every DLC of a file it is given")
        XCTAssertEqual(dragonQuest.forcedDLC(selection), Set(dragonQuest.dlc.map(\.id)))
        XCTAssertNil(try dragonQuest.plan(.defaults(for: dragonQuest)).packageVersion)
    }

    func testAGameWithoutItsBaseCannotBePlanned() {
        let listing = GameFolder.group([(package("Game [0100BBBB00020800][v65536].nsp", [(0x0100BBBB00020800, 65_536)]), nil)])
        XCTAssertFalse(listing.games[0].hasBase)
        XCTAssertThrowsError(try listing.games[0].plan(.defaults(for: listing.games[0])))
    }

    func testALinkCarriesTheTagsTheEngineReadsFromAName() {
        let untagged = package("Some Update.nsp", [(0x0100BBBB00020800, 65_536)])
        XCTAssertEqual(FolderGame.linkName(for: untagged), "Some Update [0100BBBB00020800][v65536].nsp")
        let tagged = package("Game [0100BBBB00020800][v65536].nsp", [(0x0100BBBB00020800, 65_536)])
        XCTAssertEqual(FolderGame.linkName(for: tagged), tagged.fileName)
        let compressed = package("Some Update.nsz", [(0x0100BBBB00020800, 65_536)])
        XCTAssertEqual(FolderGame.linkName(for: compressed), "Some Update.nsz",
                       "nsz names its output after the file, and the engine looks for that name")
        let merged = package("Super.xci", [(0x0100A9D01C446000, 0), (0x0100A9D01C446800, 65_536)])
        XCTAssertEqual(FolderGame.linkName(for: merged), "Super.xci", "the engine reads a merged file's contents itself")
    }

    func testTheInputFolderHoldsLinksAndKeepsTheEnginesOwnFiles() throws {
        let base = try write("games/A [0100AAAA00010000][v0].nsp")
        let update = try write("elsewhere/A update.nsp")
        let plan = BuildPlan(titleID: "0100AAAA00010000", name: "A",
                             inputs: [.init(source: base, linkName: base.lastPathComponent),
                                      .init(source: update, linkName: "A update [0100AAAA00010800][v65536].nsp")],
                             version: 65_536, packageVersion: nil, dlcTitleIDs: [],
                             workFolder: root.appendingPathComponent("games/0100AAAA00010000_build"), compressed: false)
        try FileManager.default.createDirectory(at: plan.inputFolder.appendingPathComponent("0100AAAA00010000_survey"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: plan.inputFolder.appendingPathComponent("stale.nsp"),
                                                   withDestinationURL: base)
        try BuildInputs.prepare(plan)
        let names = try FileManager.default.contentsOfDirectory(atPath: plan.inputFolder.path).sorted()
        XCTAssertEqual(names, ["0100AAAA00010000_survey", "A [0100AAAA00010000][v0].nsp", "A update [0100AAAA00010800][v65536].nsp"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: plan.inputFolder.appendingPathComponent(names[2]).path), update.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path), "the user's file is only linked to")
    }

    func testScansSubfoldersButNotHiddenOrEngineFolders() throws {
        _ = try write("A [0100AAAA00010000][v0].nsp")
        _ = try write("deep/er/B [0100BBBB00020000][v0].NSP")
        _ = try write(".hidden/C [0100CCCC00030000][v0].nsp")
        _ = try write("0100AAAA00010000_build/nsp/A [0100AAAA00010000][v0].nsp")
        _ = try write("0100AAAA00010000_survey/x.nsp")
        _ = try write("._A [0100AAAA00010000][v0].nsp")
        _ = try write("Empty [0100DDDD00040000][v0].nsp", Data())
        _ = try write("notes.txt")
        let files = GameFolder.packageFiles(in: root).map { $0.url.lastPathComponent }
        XCTAssertEqual(files, ["A [0100AAAA00010000][v0].nsp", "B [0100BBBB00020000][v0].NSP"])
        let listing = GameFolder.scan(root) { GameFolder.identify($0, bytes: $1, keys: nil) }
        XCTAssertEqual(listing.games.map(\.titleID), ["0100AAAA00010000", "0100BBBB00020000"])
    }

    func testWithoutKeysANameWithoutTitleIDIsReportedNotDropped() throws {
        _ = try write("dump.xci")
        let listing = GameFolder.scan(root) { GameFolder.identify($0, bytes: $1, keys: nil) }
        XCTAssertTrue(listing.games.isEmpty)
        XCTAssertEqual(listing.unidentified.map { $0.url.lastPathComponent }, ["dump.xci"])
        XCTAssertTrue(listing.unidentified[0].reason.contains("prod.keys"))
    }

    func testApplicationIDOfUpdatesAndDLC() {
        XCTAssertEqual(GameFolder.applicationID(of: 0x01008F2005154000), 0x01008F2005154000)
        XCTAssertEqual(GameFolder.applicationID(of: 0x01008F2005154800), 0x01008F2005154000)
        XCTAssertEqual(GameFolder.applicationID(of: 0x01008F2005155006), 0x01008F2005154000)
        XCTAssertEqual(GameFolder.kind(of: 0x01008F2005155001), .dlc)
        XCTAssertNil(GameFolder.titleID(inName: "Game [DLC Pack] [v0].nsp"))
        XCTAssertEqual(GameFolder.titleID(inName: "Game [DLC Pack] [01008F2005155006][v0].nsp"), 0x01008F2005155006)
        XCTAssertEqual(GameFolder.version(inName: "Game [01008F2005154800][v327680] (5.92 GB).nsz"), 327_680)
        XCTAssertEqual(GameFolder.dlcName(inName: "Game [DLC Bring The Crunch] [01008F2005155006][v131072].nsp"), "Bring The Crunch")
    }

    // MARK: - Python

    private func environment(_ path: String, _ major: Int, _ minor: Int, missing: [String]) -> PythonEnvironment {
        PythonEnvironment(url: URL(fileURLWithPath: path), major: major, minor: minor, missing: missing)
    }

    func testTakesTheFirstPythonThatHasEverything() {
        let found: [String: PythonEnvironment] = [
            "/brew": environment("/brew", 3, 14, missing: ["lz4", "capstone", "fontTools", "zbic", "nsz"]),
            "/venv": environment("/venv", 3, 14, missing: []),
        ]
        let chosen = ToolchainLocator.python(candidates: ["/brew", "/venv"].map { URL(fileURLWithPath: $0) }) {
            found[$0.path]
        }
        XCTAssertEqual(chosen?.url.path, "/venv", "Homebrew's bare Python came first and used to be taken")
    }

    func testFallsBackToTheRecentPythonMissingTheLeast() {
        let found: [String: PythonEnvironment] = [
            "/old": environment("/old", 3, 9, missing: []),
            "/many": environment("/many", 3, 14, missing: ["lz4", "capstone", "nsz"]),
            "/few": environment("/few", 3, 13, missing: ["nsz"]),
        ]
        let chosen = ToolchainLocator.python(candidates: ["/old", "/many", "/few"].map { URL(fileURLWithPath: $0) }) {
            found[$0.path]
        }
        XCTAssertEqual(chosen?.url.path, "/few")
        XCTAssertFalse(chosen?.isComplete ?? true)
        XCTAssertFalse(environment("/old", 3, 9, missing: []).isComplete, "the engine needs 3.12 or later")
    }

    func testRealProbeReadsAVersion() throws {
        guard let python = PythonEnvironment.inspect(URL(fileURLWithPath: "/usr/bin/python3")) else {
            throw XCTSkip("no /usr/bin/python3 on this machine")
        }
        XCTAssertGreaterThanOrEqual(python.major, 3)
        XCTAssertTrue(python.missing.allSatisfy { PythonEnvironment.requiredModules.contains($0) }, "\(python.missing)")
    }

    // MARK: - Settings and messages

    func testSettingsSavedBeforeTheNewFieldsStillDecode() throws {
        let old = #"{"keysFile":"/k/prod.keys","bundleID":"dev.nxpocket.app","language":"","keepExtracted":true,"allowOtherMetal":false,"deleteSource":false,"gameFolder":"/games","engineRoot":"","deviceUDID":"","outputFolder":"","xcodePath":""}"#
        let settings = try JSONDecoder().decode(LauncherSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.keysFile, "/k/prod.keys")
        XCTAssertEqual(settings.gameFolder, "/games")
        XCTAssertEqual(settings.pythonPath, "")
        XCTAssertTrue(settings.sendAfterBuild)
    }

    func testTheEnginesRedLineBecomesTheFailure() {
        XCTAssertEqual(AppModel.engineError(in: "[RED] more than one game in the folder: A, B"),
                       "more than one game in the folder: A, B")
        XCTAssertNil(AppModel.engineError(in: "ok extract"))
    }

    // MARK: - The app's ID on the phone

    func testSendsToTheSuffixedIDSideStoreInstalled() throws {
        XCTAssertEqual(try DeviceTransfer.resolve("dev.nxpocket.app", among: ["com.other", "dev.nxpocket.app.ABCDE12345"],
                                                  device: "iPhone"), "dev.nxpocket.app.ABCDE12345")
        XCTAssertEqual(try DeviceTransfer.resolve("dev.nxpocket.app", among: ["dev.nxpocket.app", "dev.nxpocket.app.X"],
                                                  device: "iPhone"), "dev.nxpocket.app")
        XCTAssertThrowsError(try DeviceTransfer.resolve("dev.nxpocket.app", among: ["com.other"], device: "iPhone"))
        XCTAssertThrowsError(try DeviceTransfer.resolve("dev.nxpocket.app", among: ["dev.nxpocket.app.A", "dev.nxpocket.app.B"],
                                                        device: "iPhone"))
    }

    func testReadsDevicectlsAppListing() {
        let json = #"{"result":{"apps":[{"bundleIdentifier":"dev.nxpocket.app.ABCDE12345","name":"NXPocket"},{"name":"x"}]}}"#
        XCTAssertEqual(DeviceTransfer.bundleIDs(inAppsListing: Data(json.utf8)), ["dev.nxpocket.app.ABCDE12345"])
    }
}

/// The transfer bar: devicectl says nothing while it copies, so the phone's own listing is read for progress.
final class TransferProgressTests: XCTestCase {
    func testReadsTheSizeOfTheFileBeingCopiedFromThePhonesListing() {
        let json = #"{"result":{"deviceIdentifier":"X","files":[{"metadata":{"size":4652},"name":"package.json","relativePath":"package.json"},{"metadata":{"size":3969193424},"name":"romfs.img","relativePath":"romfs.img"}]}}"#
        XCTAssertEqual(DeviceTransfer.remoteSize(inFilesListing: Data(json.utf8), relativePath: "romfs.img"), 3_969_193_424)
        XCTAssertNil(DeviceTransfer.remoteSize(inFilesListing: Data(json.utf8), relativePath: "aoc"))
        XCTAssertNil(DeviceTransfer.remoteSize(inFilesListing: Data(#"{"error":{}}"#.utf8), relativePath: "romfs.img"))
    }
}

/// A failed transfer is marked for the phone to delete, and the error says whether the mark arrived.
final class TransferFailureTests: XCTestCase {
    private let phone = Device(udid: "00008130-TEST", name: "iPhone", model: "iPhone 15 Pro", productType: "iPhone16,1",
                               osVersion: "27.0.1", isPhysical: true, isPaired: true, isConnected: true, transport: "wired")

    /// `--remove-existing-content` empties the app's whole data container on the phone, not the folder named:
    /// it wiped the iPhone's games and saves on every failed send until 2026-11-11. No copy may carry it.
    func testNoCopyEverEmptiesSomethingOnThePhone() throws {
        let arguments = DeviceTransfer.copyArguments(source: URL(fileURLWithPath: "/tmp/.abandoned"), device: phone,
                                                     bundleID: "dev.nxpocket.app.X", destination: ".incoming/ABC/.abandoned")
        XCTAssertEqual(Array(arguments.prefix(4)), ["devicectl", "device", "copy", "to"])
        XCTAssertTrue(arguments.contains("Documents/.incoming/ABC/.abandoned"))
        XCTAssertFalse(arguments.contains("--remove-existing-content"))
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("\"--remove-existing-content\""), "\(file.lastPathComponent) passes the flag")
        }
    }

    func testTheErrorSaysWhatBecameOfThePartAlreadySent() {
        let cause = NXPocketError(.transferFailed, "the device was disconnected")
        let marked = DeviceTransfer.failure(cause, partialCopyMarked: true)
        XCTAssertEqual(marked.code, .transferFailed)
        XCTAssertEqual(marked.detail, "the device was disconnected (NXPocket on the iPhone deletes the part already sent when it next opens)")
        let left = DeviceTransfer.failure(cause, partialCopyMarked: false)
        XCTAssertTrue(left.detail.hasPrefix("the device was disconnected (the part already sent is still on the iPhone"))
        XCTAssertTrue(left.detail.contains("10 minutes"), left.detail)
    }
}
