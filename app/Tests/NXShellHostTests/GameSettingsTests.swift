import NXPocketKit
import XCTest

@testable import NXShellHost

/// A game on disk as the library reads it, with South Park's settings list (`dm/launcher.json` as the engine's build writes
/// it, trimmed to the rows these tests need) and optional env files.
private struct SettingsFixture {
    static let titleID = "0100111000200000"
    let documents: URL

    static let launcherJSON = """
    {"schema": 1, "game": "0100111000200000", "settings": [
     {"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1", "level": "basic", "options": [["1", "Docked"], ["0", "Handheld"]]},
     {"env": "DM_LANG", "kind": "choice", "section": "Game", "label": "Game language", "note": "", "default": "en-US", "options": [["en-US", "American English"], ["fr", "French"]]},
     {"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Frame-rate counter", "note": "", "default": "1", "on": "1", "off": "0"},
     {"env": "DM_RUMBLE", "kind": "toggle", "section": "Controls", "label": "Game rumble", "note": "", "default": "1", "on": "1", "off": "0"},
     {"env": "DM_RUMBLE_GAIN", "kind": "range", "section": "Controls", "label": "Rumble strength", "note": "", "default": "1.0", "needs": "DM_RUMBLE=1", "min": 0.0, "max": 3.0, "step": 0.1},
     {"env": "DM_METAL_HUD", "kind": "toggle", "section": "Performance", "label": "Performance HUD", "note": "", "default": "0", "on": "1", "off": "0"},
     {"env": "PATH", "kind": "toggle", "label": "Not a switch", "default": "0"},
     {"env": "DM_BROKEN", "kind": "choice", "label": "No options", "default": "a"},
     {"env": "DM_SHOW_FPS", "kind": "toggle", "label": "Twice", "default": "0"},
     {"env": "DM_FUTURE", "kind": "dial", "label": "Unknown kind", "default": "0"}
    ]}
    """

    init() throws {
        documents = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-settings-\(UUID().uuidString)")
        let folder = documents.appendingPathComponent("games/\(Self.titleID)", isDirectory: true)
        let framework = folder.appendingPathComponent("DmGame\(Self.titleID).framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework.appendingPathComponent("dm"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["schema": 1, "title_id": Self.titleID, "name": "Fixture", "display_version": "1.0.0",
                                       "package_version": "65536", "modules": ["main", "sdk"], "nro_count": 0,
                                       "chain": "b-3f9a2c", "loader": "FH", "framework": "DmGame\(Self.titleID).framework",
                                       "framework_executable": "DmGame\(Self.titleID)", "image_marker": "dmgame_image_marker",
                                       "profile": "profile.tsv", "shader_map": "dm/shader_map.tsv",
                                       "launcher": "dm/launcher.json", "romfs_marker": "r", "romfs_identity": "i", "min_os": "26.0"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: framework.appendingPathComponent("game.manifest.json"))
        // The library lists a game whose code is missing as damaged: the fixture carries a stand-in executable.
        try Data("stand-in".utf8).write(to: framework.appendingPathComponent("DmGame\(Self.titleID)"))
        try Data(Self.launcherJSON.utf8).write(to: framework.appendingPathComponent("dm/launcher.json"))
        let package: [String: Any] = ["schema": 1, "title_id": Self.titleID, "name": "Fixture", "version": "1.0.0",
                                      "package_version": "65536", "framework": "DmGame\(Self.titleID).framework",
                                      "chain": "b-3f9a2c", "min_os": "26.0", "romfs_id": "", "romfs_size": 0, "aoc_size": 0,
                                      "files": [], "created_by": "tests"]
        try JSONSerialization.data(withJSONObject: package).write(to: folder.appendingPathComponent("package.json"))
    }

    var game: InstalledGame { GameLibrary.entry(at: documents.appendingPathComponent("games/\(Self.titleID)")) }

    func write(_ text: String, to relative: String) throws {
        try Data(text.utf8).write(to: documents.appendingPathComponent(relative))
    }

    func plan(launchEnvironment: [String: String] = [:], touch: TouchControls? = nil) throws -> EngineLaunchPlan {
        try XCTUnwrap(EngineLaunchPlan.make(game: game, documents: documents, appResources: documents, touch: touch,
                                            launchEnvironment: launchEnvironment))
    }

    func remove() { try? FileManager.default.removeItem(at: documents) }
}

final class GameSettingsTests: XCTestCase {
    private var fixture: SettingsFixture!

    override func setUpWithError() throws { fixture = try SettingsFixture() }
    override func tearDown() { fixture.remove() }

    func testReadsTheGamesRowsInOrderAndSkipsTheOnesNoEngineLauncherWouldSet() {
        let list = LauncherSettingsList.load(for: fixture.game)
        XCTAssertEqual(list.map(\.env), ["DM_OPMODE", "DM_LANG", "DM_SHOW_FPS", "DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_METAL_HUD"])
        XCTAssertEqual(list.first { $0.env == "DM_SHOW_FPS" }?.label, "Frame-rate counter", "the first of two rows wins")
    }

    func testAGameWithoutASettingsListStartsWithNoSettingFromTheShell() throws {
        try FileManager.default.removeItem(at: fixture.game.frameworkURL!.appendingPathComponent("dm/launcher.json"))
        let plan = try fixture.plan()
        XCTAssertNil(plan.environment["DM_OPMODE"])
        XCTAssertEqual(plan.environment["DM_TOUCH_SIZE"], "medium", "the touch controls still apply")
    }

    func testOnlyAChoiceThatDiffersFromTheDefaultIsKept() {
        var settings = GameSettings(list: LauncherSettingsList.load(for: fixture.game))
        XCTAssertTrue(settings.choose("DM_OPMODE", "0"))
        XCTAssertTrue(settings.choose("DM_RUMBLE_GAIN", "1.00"))
        XCTAssertEqual(settings.choices.values, ["DM_OPMODE": "0"], "1.00 is the default 1.0: a range compares as numbers")
        XCTAssertTrue(settings.choose("DM_OPMODE", "1"))
        XCTAssertTrue(settings.choices.values.isEmpty, "back to the default, the choice is forgotten and follows a later build")
    }

    func testRefusesAValueTheGameDoesNotOffer() {
        var settings = GameSettings(list: LauncherSettingsList.load(for: fixture.game))
        XCTAssertFalse(settings.choose("DM_OPMODE", "2"))
        XCTAssertFalse(settings.choose("DM_RUMBLE_GAIN", "3.5"))
        XCTAssertFalse(settings.choose("DM_RUMBLE_GAIN", "0x1"), "no hex, as the engine's own check")
        XCTAssertFalse(settings.choose("DM_NOT_IN_THE_LIST", "1"))
        XCTAssertTrue(settings.choices.values.isEmpty)
    }

    func testAKeptChoiceTheGameNoLongerOffersReadsAsItsDefault() {
        let settings = GameSettings(list: LauncherSettingsList.load(for: fixture.game),
                                    choices: GameChoices(values: ["DM_LANG": "ja"]))
        let lang = settings.setting("DM_LANG")!
        XCTAssertEqual(settings.value(of: lang), "en-US")
        XCTAssertEqual(settings.environment["DM_LANG"], "en-US")
        XCTAssertFalse(settings.hasChoices, "Reset has nothing to bring back")
    }

    func testASubSettingShowsOnlyWhileTheSettingItNeedsHasThatValue() {
        var settings = GameSettings(list: LauncherSettingsList.load(for: fixture.game))
        XCTAssertTrue(settings.sections().flatMap(\.rows).contains { $0.env == "DM_RUMBLE_GAIN" })
        settings.choose("DM_RUMBLE", "0")
        XCTAssertFalse(settings.sections().flatMap(\.rows).contains { $0.env == "DM_RUMBLE_GAIN" })
        XCTAssertEqual(settings.environment["DM_RUMBLE_GAIN"], "1.0", "a hidden row still starts at its value")
    }

    func testTheSectionsKeepTheListsOrderAndLeaveOutTheQuickSwitches() {
        let settings = GameSettings(list: LauncherSettingsList.load(for: fixture.game))
        XCTAssertEqual(QuickSetting.shown(settings), ["DM_OPMODE", "DM_SHOW_FPS"])
        let sections = settings.sections(excluding: QuickSetting.shown(settings))
        XCTAssertEqual(sections.map(\.title), ["Game", "Controls", "Performance"])
        XCTAssertEqual(sections[0].rows.map(\.env), ["DM_LANG"])
    }

    func testChoicesAreKeptOutsideTheGameFolderWhichAnUpdateReplaces() throws {
        try GameChoices(values: ["DM_OPMODE": "0"]).save(titleID: SettingsFixture.titleID, documents: fixture.documents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.documents
            .appendingPathComponent("settings/\(SettingsFixture.titleID).json").path))
        try FileManager.default.removeItem(at: fixture.documents.appendingPathComponent("games/\(SettingsFixture.titleID)"))
        XCTAssertEqual(GameChoices.load(titleID: SettingsFixture.titleID, documents: fixture.documents).values, ["DM_OPMODE": "0"])
    }

    func testADamagedChoicesFileReadsAsNoChoice() throws {
        try FileManager.default.createDirectory(at: fixture.documents.appendingPathComponent("settings"), withIntermediateDirectories: true)
        try fixture.write("{not json", to: "settings/\(SettingsFixture.titleID).json")
        XCTAssertTrue(GameChoices.load(titleID: SettingsFixture.titleID, documents: fixture.documents).values.isEmpty)
    }

    // MARK: - At launch

    func testEverySettingReachesTheEngineAtItsDefaultWhenNothingIsChosen() throws {
        let environment = try fixture.plan().environment
        XCTAssertEqual(environment["DM_OPMODE"], "1")
        XCTAssertEqual(environment["DM_SHOW_FPS"], "1")
        XCTAssertEqual(environment["DM_LANG"], "en-US")
        XCTAssertEqual(environment["DM_RUMBLE_GAIN"], "1.0")
        XCTAssertNil(environment["PATH"], "a malformed row never becomes a variable")
        XCTAssertEqual(environment["DM_LAUNCHER"], "0", "the game's own settings screen stays away")
    }

    func testTheGamesKeptChoicesReachTheEngine() throws {
        try GameChoices(values: ["DM_OPMODE": "0", "DM_SHOW_FPS": "0", "DM_LANG": "fr"])
            .save(titleID: SettingsFixture.titleID, documents: fixture.documents)
        let environment = try fixture.plan().environment
        XCTAssertEqual(environment["DM_OPMODE"], "0")
        XCTAssertEqual(environment["DM_SHOW_FPS"], "0")
        XCTAssertEqual(environment["DM_LANG"], "fr")
    }

    func testAnEnvFileWinsOverTheChoiceAndTheGamesOwnFileOverTheSharedOne() throws {
        try GameChoices(values: ["DM_OPMODE": "0", "DM_SHOW_FPS": "0"])
            .save(titleID: SettingsFixture.titleID, documents: fixture.documents)
        try fixture.write("DM_OPMODE=1\nDM_SHOW_FPS=1\n", to: "env.txt")
        try fixture.write("# the game's own\nDM_SHOW_FPS=0\n", to: "games/\(SettingsFixture.titleID)/env.txt")
        let environment = try fixture.plan().environment
        XCTAssertEqual(environment["DM_OPMODE"], "1", "Documents/env.txt wins over the player's choice")
        XCTAssertEqual(environment["DM_SHOW_FPS"], "0", "the game's env.txt wins over Documents/env.txt")
        XCTAssertEqual(Set(environment["DM_ENV_FILE_KEYS"]!.split(separator: " ")), ["DM_OPMODE", "DM_SHOW_FPS"])
        XCTAssertEqual(environment["DM_ENV_LAUNCH_KEYS"], "")
    }

    func testTheLaunchEnvironmentWinsOverTheEnvFilesAndTheChoices() throws {
        try GameChoices(values: ["DM_OPMODE": "0"]).save(titleID: SettingsFixture.titleID, documents: fixture.documents)
        try fixture.write("DM_METAL_HUD=1\n", to: "env.txt")
        let environment = try fixture.plan(launchEnvironment: ["DM_OPMODE": "1", "DM_METAL_HUD": "0", "HOME": "/x"]).environment
        XCTAssertEqual(environment["DM_OPMODE"], "1")
        XCTAssertEqual(environment["DM_METAL_HUD"], "0")
        XCTAssertNil(environment["HOME"], "only DM_ variables count")
        XCTAssertEqual(environment["DM_ENV_LAUNCH_KEYS"], "DM_METAL_HUD DM_OPMODE")
        XCTAssertEqual(environment["DM_ENV_FILE_KEYS"], "")
    }

    func testTheShellsOwnPathsStayWhateverAnEnvFileSays() throws {
        try fixture.write("DM_SAVE=/elsewhere\n", to: "env.txt")
        let plan = try fixture.plan()
        XCTAssertEqual(plan.environment["DM_SAVE"], fixture.game.directory.appendingPathComponent("save").path)
    }

    @MainActor
    func testTheDetailScreenShowsARowAnEnvFileFixesAndWillNotChangeIt() async throws {
        try fixture.write("DM_OPMODE=1\n", to: "env.txt")
        let model = ShellHostModel(documents: fixture.documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        await model.libraryRead()
        let game = try XCTUnwrap(model.games.first)
        let settings = model.settings(for: game)
        XCTAssertEqual(settings.lock(of: settings.setting("DM_OPMODE")!), .envFile("env.txt"))
        XCTAssertNil(settings.lock(of: settings.setting("DM_SHOW_FPS")!))
        let after = model.choose("DM_OPMODE", "0", in: settings, for: game)
        XCTAssertEqual(after.value(of: after.setting("DM_OPMODE")!), "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: GameChoices.url(titleID: SettingsFixture.titleID,
                                                                               documents: fixture.documents).path))
    }

    @MainActor
    func testAChoiceMadeOnTheScreenIsWhatTheNextLaunchApplies() async throws {
        let model = ShellHostModel(documents: fixture.documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        await model.libraryRead()
        let game = try XCTUnwrap(model.games.first)
        var settings = model.choose("DM_OPMODE", "0", in: model.settings(for: game), for: game)
        settings = model.choose("DM_SHOW_FPS", "0", in: settings, for: game)
        XCTAssertEqual(model.settings(for: game), settings, "read back from disk as it was left")
        XCTAssertEqual(try fixture.plan().environment["DM_OPMODE"], "0")
        settings = model.resetSettings(settings, for: game)
        XCTAssertFalse(settings.hasChoices)
        XCTAssertEqual(try fixture.plan().environment["DM_SHOW_FPS"], "1")
    }

    // MARK: - Touch controls at launch

    func testTheTouchControlsReachEveryGameAndTheLayoutOnlyWhenSomethingMoved() throws {
        var environment = try fixture.plan(touch: TouchControls()).environment
        XCTAssertEqual(environment["DM_TOUCH_SIZE"], "medium")
        XCTAssertEqual(environment["DM_TOUCH_STICK"], "corner")
        XCTAssertNil(environment["DM_TOUCH_LAYOUT"])
        var layout = TouchLayout()
        layout[.twoD, .face] = .init(dx: 0, dy: -2)
        environment = try fixture.plan(touch: TouchControls(size: .large, stick: .inward, layout: layout)).environment
        XCTAssertEqual(environment["DM_TOUCH_SIZE"], "large")
        XCTAssertEqual(environment["DM_TOUCH_STICK"], "inward")
        XCTAssertEqual(environment["DM_TOUCH_LAYOUT"], "1;2d/face:0,-2")
    }

    func testTheTouchControlsAreReadFromTheSettingsFolderWhenNotGiven() throws {
        var layout = TouchLayout()
        layout[.threeD, .dpad] = .init(dx: 3, dy: 0)
        try TouchControls(size: .small, stick: .higher, layout: layout).save(documents: fixture.documents)
        let environment = try fixture.plan().environment
        XCTAssertEqual(environment["DM_TOUCH_SIZE"], "small")
        XCTAssertEqual(environment["DM_TOUCH_STICK"], "higher")
        XCTAssertEqual(environment["DM_TOUCH_LAYOUT"], "1;3d/dpad:3,0")
    }

    func testAnEnvFileWinsOverTheTouchControlsToo() throws {
        try fixture.write("DM_TOUCH_SIZE=small\n", to: "env.txt")
        XCTAssertEqual(try fixture.plan(touch: TouchControls(size: .large)).environment["DM_TOUCH_SIZE"], "small")
    }

    func testTheRightStickHintGoesInThePlayersLanguage() throws {
        let plan = try XCTUnwrap(EngineLaunchPlan.make(game: fixture.game, documents: fixture.documents,
                                                       appResources: fixture.documents, touchHint: "Stick droit : glisse ici"))
        XCTAssertEqual(plan.environment["DM_TOUCH_HINT"], "Stick droit : glisse ici")
    }

    func testASliderKeepsAsManyDecimalsAsItsStep() {
        XCTAssertEqual(SettingSlider.format(1, step: 0.1), "1.0")
        XCTAssertEqual(SettingSlider.format(0.35, step: 0.05), "0.35")
        XCTAssertEqual(SettingSlider.format(2, step: 1), "2")
    }

    func testTheIconIsFoundInTheFrameworkWhenTheManifestNamesNone() throws {
        let game = fixture.game
        XCTAssertNil(GameArtwork.iconURL(for: game))
        let icon = game.frameworkURL!.appendingPathComponent("icon.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: icon)
        XCTAssertEqual(GameArtwork.iconURL(for: game)?.path, icon.path)
    }
}
