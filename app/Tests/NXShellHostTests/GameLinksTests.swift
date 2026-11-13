import NXPocketKit
import UIKit
import XCTest

@testable import NXShellHost

final class GameLinkTests: XCTestCase {
    func testAPlayLinkNamesItsGameAndNothingElseDoes() throws {
        XCTAssertEqual(GameLink.titleID(from: URL(string: "nxpocket://play/010043600B6A6000")!)?.description, "010043600B6A6000")
        XCTAssertEqual(GameLink.titleID(from: URL(string: "NXPocket://PLAY/010043600b6a6000")!)?.description, "010043600B6A6000")
        for text in ["nxpocket://play/010043600B6A600", "nxpocket://play/010043600B6A60000", "nxpocket://play/01004360OB6A6000",
                     "nxpocket://play/010043600B6A6000/x", "nxpocket://play/010043600B6A6000?x=1", "nxpocket://open/010043600B6A6000",
                     "nxpocket://play", "https://play/010043600B6A6000", "nxpocket://play/../010043600B6A6000",
                     "nxpocket://user@play/010043600B6A6000", "nxpocket://play/010043600B6A6800"] {
            XCTAssertNil(GameLink.titleID(from: URL(string: text)!), text)
        }
        let id = try XCTUnwrap(TitleID("010043600B6A6000"))
        XCTAssertEqual(GameLink.titleID(from: GameLink.url(for: id)), id)
    }

    func testTheNextLaunchIsTakenOnceAndOnlyWithinTwoMinutes() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-next-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        let id = try XCTUnwrap(TitleID("010043600B6A6000"))
        let now = Date()
        try NextLaunch.write(id, documents: documents, now: now)
        XCTAssertEqual(NextLaunch.take(documents: documents, now: now.addingTimeInterval(60)), id)
        XCTAssertNil(NextLaunch.take(documents: documents, now: now.addingTimeInterval(61)), "read once")
        try NextLaunch.write(id, documents: documents, now: now)
        XCTAssertNil(NextLaunch.take(documents: documents, now: now.addingTimeInterval(121)), "too old to be a request")
        XCTAssertFalse(FileManager.default.fileExists(atPath: NextLaunch.url(documents: documents).path), "gone either way")
        try Data("not json".utf8).write(to: NextLaunch.url(documents: documents))
        XCTAssertNil(NextLaunch.take(documents: documents))
    }
}

final class ShortcutProfileTests: XCTestCase {
    private var fixture: LibraryFixture!

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    func testTheProfileHoldsOneWebClipOpeningTheGameWithIdentifiersThatOnlyTheTitleIDDecides() throws {
        let texts = ShortcutProfile.Texts(label: "South Park", displayName: "NXPocketApple : South Park", description: "d")
        let url = try ShortcutProfile.write(fixture.game, texts: texts, documents: fixture.documents)
        XCTAssertEqual(url.path, fixture.documents.appendingPathComponent("Shortcuts/South Park.mobileconfig").path)
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(profile["PayloadIdentifier"] as? String, "dev.nxpocketapple.shortcut.\(LibraryFixture.titleID)")
        XCTAssertEqual(profile["PayloadDisplayName"] as? String, "NXPocketApple : South Park")
        XCTAssertEqual(profile["PayloadOrganization"] as? String, "NXPocketApple")
        let clips = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(clips.count, 1)
        let clip = clips[0]
        XCTAssertEqual(clip["PayloadType"] as? String, "com.apple.webClip.managed")
        XCTAssertEqual(clip["Label"] as? String, "South Park")
        XCTAssertEqual(clip["URL"] as? String, "nxpocket://play/\(LibraryFixture.titleID)")
        XCTAssertEqual(clip["IsRemovable"] as? Bool, true)
        XCTAssertEqual(clip["FullScreen"] as? Bool, false)
        XCTAssertEqual(clip["Precomposed"] as? Bool, true)
        let icon = try XCTUnwrap(UIImage(data: try XCTUnwrap(clip["Icon"] as? Data)))
        XCTAssertEqual(icon.size.width * icon.scale, 180)
        XCTAssertEqual(icon.size.height * icon.scale, 180)

        let again = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: ShortcutProfile.data(titleID: fixture.game.titleID, texts: texts, icon: nil), format: nil) as? [String: Any])
        XCTAssertEqual(again["PayloadUUID"] as? String, profile["PayloadUUID"] as? String, "installing it again replaces it")
        let other = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: ShortcutProfile.data(titleID: TitleID("0100222000300000")!, texts: texts, icon: nil), format: nil) as? [String: Any])
        XCTAssertNotEqual(other["PayloadUUID"] as? String, profile["PayloadUUID"] as? String)
        XCTAssertNotNil(UUID(uuidString: profile["PayloadUUID"] as? String ?? ""))
    }

    func testAnIconIsDecodedAtABoundedSize() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 2400), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 2400))
        }
        let url = fixture.documents.appendingPathComponent("big.png")
        try XCTUnwrap(big.pngData()).write(to: url)
        let thumbnail = try XCTUnwrap(GameArtwork.thumbnail(at: url, maxPixels: GameArtwork.maxPixels))
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), GameArtwork.maxPixels)
        try Data("not an image".utf8).write(to: url)
        XCTAssertNil(GameArtwork.thumbnail(at: url, maxPixels: 100))
    }
}

final class LaunchFromIconTests: XCTestCase {
    private var fixture: LibraryFixture!

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    @MainActor
    private func model() async -> ShellHostModel {
        let model = ShellHostModel(documents: fixture.documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        await model.libraryRead()
        return model
    }

    @MainActor
    func testANextLaunchLeftByASwitchStartsItsGameOnceTheFirstScreenIsUp() async throws {
        try NextLaunch.write(fixture.game.titleID, documents: fixture.documents)
        let model = await model()
        XCTAssertEqual(model.launch, .idle, "nothing starts before the first screen")
        model.firstScreenAppeared()
        // No certificate in the tests: the start is refused, which shows it was asked for, in the player's words.
        XCTAssertEqual(model.launch, .failed(model.text(.certificateNeededToPlay)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: NextLaunch.url(documents: fixture.documents).path))
    }

    @MainActor
    func testALinkToAGameWhoseLastStartCrashedLeavesItInTheLibrary() async throws {
        try LaunchGuard.willLaunch(titleID: fixture.game.titleID, in: fixture.documents)
        let model = await model()
        model.firstScreenAppeared()
        model.open(GameLink.url(for: fixture.game.titleID))
        XCTAssertEqual(model.launch, .idle)
        XCTAssertEqual(model.failedLaunch?.titleID, LibraryFixture.titleID, "the notice says why")
    }

    @MainActor
    func testALinkThatNamesNoGameIsIgnored() async throws {
        let model = await model()
        model.firstScreenAppeared()
        model.open(URL(string: "nxpocket://play/0100999000000000")!)
        model.open(URL(string: "nxpocket://delete/\(LibraryFixture.titleID)")!)
        XCTAssertEqual(model.launch, .idle)
    }

    func testAMarkerTooDamagedToReadIsStillAFailedLaunch() throws {
        try Data("{\"titleID\":".utf8).write(to: LaunchMarker.url(in: fixture.documents))
        XCTAssertEqual(LaunchGuard.failedLaunch(in: fixture.documents)?.titleID, TitleID(rawValue: 0).description)
    }
}

final class LaunchHardeningTests: XCTestCase {
    private var fixture: LibraryFixture!

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    private func plan() throws -> EngineLaunchPlan {
        try XCTUnwrap(EngineLaunchPlan.make(game: fixture.game, documents: fixture.documents, appResources: fixture.documents))
    }

    func testTheExecutableMustBeARegularFileInsideTheFramework() throws {
        var plan = try plan()
        XCTAssertNoThrow(try plan.checkExecutable(), "the fixture's own executable")
        let outside = fixture.documents.appendingPathComponent("elsewhere")
        try Data("x".utf8).write(to: outside)
        let link = plan.framework.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        plan.frameworkExecutable = link
        XCTAssertThrowsError(try plan.checkExecutable(), "a link, even one inside the framework")
        plan.frameworkExecutable = outside
        XCTAssertThrowsError(try plan.checkExecutable(), "a file outside the framework")
        plan.frameworkExecutable = plan.framework.appendingPathComponent("../../../elsewhere")
        XCTAssertThrowsError(try plan.checkExecutable())
        plan.frameworkExecutable = plan.framework.appendingPathComponent("Missing")
        XCTAssertThrowsError(try plan.checkExecutable())
    }

    func testAnEnvFileSetsOnlyTheEnginesOwnVariables() throws {
        try Data("HOME=/tmp\nDYLD_INSERT_LIBRARIES=/x.dylib\nMTL_HUD_ENABLED=0\nDM_OPMODE=0\n".utf8)
            .write(to: fixture.documents.appendingPathComponent("env.txt"))
        let keys = EngineLaunchPlan.presets(game: fixture.game, documents: fixture.documents).map(\.key)
        XCTAssertEqual(keys, ["DM_OPMODE"])
        let environment = try plan().environment
        XCTAssertNil(environment["HOME"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(environment["DM_OPMODE"], "0")
    }

    func testTheMarkerHasToLieInTheFileThatWasLoaded() throws {
        let handle = try XCTUnwrap(dlopen("/usr/lib/libz.1.dylib", RTLD_NOW | RTLD_LOCAL))
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(try XCTUnwrap(dlsym(handle, "deflate")), &info), 0)
        let real = String(cString: try XCTUnwrap(info.dli_fname))
        let base = UnsafeRawPointer(try XCTUnwrap(info.dli_fbase))
        XCTAssertNoThrow(try FrameworkLoader.verify(LoadedFramework(handle: handle, imageBase: base, path: real), marker: "deflate"))
        XCTAssertThrowsError(try FrameworkLoader.verify(LoadedFramework(handle: handle, imageBase: base,
                                                                        path: fixture.game.executableURL!.path), marker: "deflate"),
                             "the same symbol found from another file's handle proves nothing about that file")
    }

    func testAnExpiredCertificateDoesNotSignAgain() throws {
        let service = ImportService(documents: fixture.documents, signer: UnavailableSigner())
        let expired = SigningIdentity(identifier: "dev.nxpocketapple.app", teamID: "ABCDE12345",
                                      certificateSHA256: String(repeating: "a", count: 64), subject: "Apple Development: Test",
                                      expires: Date().addingTimeInterval(-60))
        XCTAssertThrowsError(try service.resign(fixture.game, identity: expired)) {
            XCTAssertEqual(($0 as? NXPocketError)?.code, .certificateExpired)
        }
    }

    func testTheCertificateAndItsPasswordTravelAsOneKeychainValue() throws {
        let data = try CertificateVault.encode(p12: Data([1, 2, 3]), passphrase: "pass word")
        let decoded = try XCTUnwrap(CertificateVault.decode(data))
        XCTAssertEqual(decoded.p12, Data([1, 2, 3]))
        XCTAssertEqual(decoded.passphrase, "pass word")
        XCTAssertNil(CertificateVault.decode(Data("junk".utf8)))
    }
}

final class SaveRecoveryTests: XCTestCase {
    private var fixture: LibraryFixture!

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    func testSavesAnEarlierVersionLeftInHiddenFoldersComeBackOrBecomeACopyFilesShows() throws {
        let games = fixture.documents.appendingPathComponent("games")
        let keeper = games.appendingPathComponent(".saves-old", isDirectory: true)
        try FileManager.default.createDirectory(at: keeper.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("lost".utf8).write(to: keeper.appendingPathComponent("save/a.bin"))
        try GameSaves.delete(in: fixture.game)
        let aside = fixture.folder.appendingPathComponent(".saves-aside", isDirectory: true)
        try FileManager.default.createDirectory(at: aside.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("aside".utf8).write(to: aside.appendingPathComponent("save/slot1.bin"))

        let notes = GameSaves.recoverHiddenCopies(documents: fixture.documents)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(fixture.text("save/slot1.bin"), "aside", "a game with no saves gets them back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keeper.path))
        let recovered = GameSaves.keptFolder(titleID: "Recovered", documents: fixture.documents)
        let copies = try FileManager.default.contentsOfDirectory(atPath: recovered.path)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(fixture.text("save/a.bin", in: recovered.appendingPathComponent(copies[0])), "lost")
    }

    func testRemovingAGameButNotItsSavesLeavesThemWhereTheyWere() throws {
        try GameRemoval.remove(fixture.game, includingSaves: false)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).sorted(), ["save", "save_meta.dat"])
        XCTAssertEqual(fixture.text("save/slot1.bin"), "old slot")
    }

    func testALargeEntryIsWrittenInPiecesBothStoredAndDeflated() throws {
        let bytes = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 12)) })
        let stored = fixture.documents.appendingPathComponent("stored.zip")
        try StoredZip.write([("copy/save/big.bin", bytes)], to: stored)
        let out = fixture.documents.appendingPathComponent("out-stored")
        try SaveArchive.extract(stored, into: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("copy/save/big.bin")), bytes)

        let folder = fixture.documents.appendingPathComponent("to-zip/copy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("big.bin"))
        let deflated = fixture.documents.appendingPathComponent("deflated.zip")
        try SaveArchive.zip(folder: folder, to: deflated)
        let inflated = fixture.documents.appendingPathComponent("out-deflated")
        try SaveArchive.extract(deflated, into: inflated)
        XCTAssertEqual(try Data(contentsOf: inflated.appendingPathComponent("copy/big.bin")), bytes)
        XCTAssertThrowsError(try SaveArchive.extract(deflated, into: inflated, maxBytes: 1 << 20)) {
            XCTAssertEqual($0 as? SaveArchive.Failure, .tooLarge)
        }
    }

    func testAPickedFolderOfAnotherGameIsRefusedBeforeAnythingIsCopied() throws {
        let other = try fixture.macCopy(titleID: "0100222000300000")
        let staging = fixture.documents.appendingPathComponent(".saves-staging", isDirectory: true)
        XCTAssertThrowsError(try GameSaves.read(other, for: LibraryFixture.titleID, staging: staging))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [], [], "nothing was copied")
    }
}

/// A host whose game is "on screen" in a window of the test app's scene, to see where the switch question goes.
@MainActor
private final class WindowedHost: EngineHost {
    let window: UIWindow
    init() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }
    var isAvailable: Bool { true }
    func start(_ plan: EngineLaunchPlan) throws -> String? { nil }
    func present() -> String? { nil }
    var gameWindow: UIWindow? { window }
}

final class SwitchGameTests: XCTestCase {
    private var fixture: LibraryFixture!

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    @MainActor
    func testAnotherGamesIconWhileAGameRunsAsksOnTheGamesWindowAndTheSameGamesIconDoesNothing() async throws {
        let host = WindowedHost()
        defer { host.window.isHidden = true }
        let model = ShellHostModel(documents: fixture.documents, engineHost: host, signer: UnavailableSigner())
        await model.libraryRead()
        model.language = "fr"
        model.rename(try XCTUnwrap(model.games.first), to: "South Park")
        model.activeTitleID = LibraryFixture.titleID
        model.launch = .running("South Park")

        model.open(GameLink.url(for: try XCTUnwrap(TitleID(LibraryFixture.titleID))))
        XCTAssertNil(host.window.rootViewController?.presentedViewController, "the same game: nothing to ask")

        model.open(URL(string: "nxpocket://play/0100222000300000")!)
        let alert = try XCTUnwrap(host.window.rootViewController?.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "Fermer South Park ?")
        XCTAssertEqual(alert.actions.map(\.title), ["Fermer South Park", model.text(.cancel)])
        XCTAssertEqual(alert.actions.first?.style, .destructive)
        XCTAssertEqual(alert.message, "0100222000300000 s'ouvrira quand tu toucheras de nouveau son icône. "
                                      + "Ce que South Park n'a pas sauvegardé sera perdu.")
        alert.dismiss(animated: false)
    }
}
