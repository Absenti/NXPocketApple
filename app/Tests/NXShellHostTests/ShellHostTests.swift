import NXPocketKit
import XCTest

@testable import NXShellHost

final class ImportServiceTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func makeGame(folder: String = ".incoming/transfer") throws -> URL {
        let root = workspace.appendingPathComponent(folder)
        let framework = root.appendingPathComponent("DmGame0100111000200000.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try SyntheticMachO.dylib().write(to: framework.appendingPathComponent("DmGame"))
        let manifest: [String: Any] = ["schema": 1, "title_id": "0100111000200000", "name": "Fixture",
                                       "display_version": "1.0.0", "package_version": "65536", "modules": ["main"],
                                       "nro_count": 0, "chain": "b-3f9a2c", "loader": "FR",
                                       "framework": "DmGame0100111000200000.framework", "framework_executable": "DmGame",
                                       "image_marker": "m", "profile": "p.tsv", "shader_map": "s.tsv",
                                       "launcher": "dm/launcher.json", "romfs_marker": "r", "romfs_identity": "i",
                                       "min_os": "26.0"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: framework.appendingPathComponent("game.manifest.json"))
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>DmGame</string></dict></plist>".utf8)
            .write(to: framework.appendingPathComponent("Info.plist"))

        var files: [[String: Any]] = []
        for item in try PackageScanner.files(in: framework) {
            files.append(["path": item.relativePath, "size": item.size,
                          "sha256": try FileDigest.sha256(ofFileAt: item.url)])
        }
        let package: [String: Any] = ["schema": 1, "title_id": "0100111000200000", "name": "Fixture",
                                      "version": "1.0.0", "package_version": "65536",
                                      "framework": "DmGame0100111000200000.framework", "chain": "b-3f9a2c",
                                      "min_os": "26.0", "romfs_id": "", "romfs_size": 0, "aoc_size": 0,
                                      "files": files, "created_by": "tests"]
        try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("package.json"))
        try Data("complete\n".utf8).write(to: root.appendingPathComponent(".complete"))
        return root
    }

    private var identity: SigningIdentity {
        SigningIdentity(identifier: "dev.nxpocket.app", teamID: "ABCDE12345",
                        certificateSHA256: String(repeating: "a", count: 64),
                        subject: "Apple Development: Test", expires: Date().addingTimeInterval(5 * 86400))
    }

    func testImportsAFinishedTransfer() throws {
        _ = try makeGame()
        let service = ImportService(documents: workspace, signer: AcceptingSigner())
        let games = try service.importAll(identity: identity)
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.titleID.description, "0100111000200000")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("games/0100111000200000/package.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".incoming/transfer").path))
    }

    func testIgnoresATransferWithoutTheCompleteMarker() throws {
        let root = try makeGame(folder: ".incoming/unfinished")
        try FileManager.default.removeItem(at: root.appendingPathComponent(".complete"))
        let service = ImportService(documents: workspace, signer: AcceptingSigner())
        XCTAssertTrue(try service.importAll(identity: identity).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRefusesToImportWithNoCertificate() throws {
        let root = try makeGame()
        let service = ImportService(documents: workspace, signer: AcceptingSigner())
        XCTAssertThrowsError(try service.importAll(identity: nil)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .noCertificate)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("games/0100111000200000").path),
                       "an unsigned game never reaches the library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "and its transfer is left in place")
    }

    func testResignsAGameInPlace() throws {
        _ = try makeGame()
        let service = ImportService(documents: workspace, signer: AcceptingSigner())
        let game = try XCTUnwrap(try service.importAll(identity: identity).first)
        var other = identity
        other.certificateSHA256 = String(repeating: "b", count: 64)
        XCTAssertTrue(service.gamesNeedingSignature([game], identity: other).count == 1)
        _ = try service.resign(game, identity: other)
        XCTAssertNotNil(GameLibrary.readSigning(game.directory))
    }

    func testRemovesUnfinishedTransfersOnly() throws {
        let service = ImportService(documents: workspace, signer: AcceptingSigner())
        let finished = try makeGame(folder: ".incoming/finished")
        let cut = workspace.appendingPathComponent(".incoming/cut")
        try FileManager.default.createDirectory(at: cut, withIntermediateDirectories: true)
        let later = Date().addingTimeInterval(GameLayout.incomingIdleLimit + 60)
        XCTAssertEqual(service.cleanUnfinishedTransfers(now: later).map(\.lastPathComponent), ["cut"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
    }

    func testRemovesATransferRefusedForItsContent() throws {
        let root = try makeGame()
        // One byte more than package.json lists: the copy that reached the phone is not the one that was built.
        let executable = root.appendingPathComponent("DmGame0100111000200000.framework/DmGame")
        let handle = try FileHandle(forWritingTo: executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let service = ImportService(documents: workspace, signer: AcceptingSigner())
        XCTAssertThrowsError(try service.importAll(identity: identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "importing it again would fail the same way")
    }

    func testKeepsATransferRefusedForTheSignature() throws {
        let root = try makeGame()
        let service = ImportService(documents: workspace, signer: UnavailableSigner())
        XCTAssertThrowsError(try service.importAll(identity: identity)) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .signingFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "it can be imported once signing works")
    }

    @MainActor
    func testOpeningTheAppRemovesAnAbandonedTransfer() throws {
        let abandoned = workspace.appendingPathComponent(".incoming/abandoned")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("abandoned\n".utf8).write(to: abandoned.appendingPathComponent(GameLayout.abandonedMarker))
        _ = ShellHostModel(documents: workspace, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }
}

final class GameRemovalTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("games/0100111000200000/save"),
                                                withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: workspace.appendingPathComponent("games/0100111000200000/save/progress.dat"))
        try Data("code".utf8).write(to: workspace.appendingPathComponent("games/0100111000200000/romfs.img"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    private var game: InstalledGame {
        InstalledGame(titleID: TitleID("0100111000200000")!,
                      directory: workspace.appendingPathComponent("games/0100111000200000"),
                      dataBytes: 6)
    }

    func testKeepsTheSaves() throws {
        try GameRemoval.remove(game, saves: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("games/0100111000200000/save/progress.dat").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("games/0100111000200000/romfs.img").path))
    }

    func testRemovesTheSavesWhenAsked() throws {
        try GameRemoval.remove(game, saves: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("games/0100111000200000").path))
    }

    func testMeasuresTheSaves() {
        XCTAssertEqual(GameRemoval.saveBytes(of: game), 8)
    }
}

final class ShellHostModelTests: XCTestCase {
    @MainActor
    func testStartsEmptyOnAFreshDocumentsFolder() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let model = ShellHostModel(documents: workspace, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        XCTAssertTrue(model.games.isEmpty)
        XCTAssertNil(model.certificate)
        XCTAssertNil(model.signingIdentity)
        XCTAssertNil(model.failedLaunchLog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("games").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".incoming").path))
    }

    @MainActor
    func testRefusesToPlayWithoutAnEngineHost() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-play-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = ShellHostModel(documents: workspace, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        model.play(model.games.first ?? InstalledGame(titleID: TitleID("0100111000200000")!,
                                                     directory: workspace, problem: NXPocketError(.packageDamaged, "damaged")))
        guard case .failed(let message) = model.launch else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("damaged") || message.contains("engine") || message.contains("certificate"),
                      "the refusal says why: \(message)")
    }

    // MARK: - Load test

    @MainActor
    func testLoadTestRefusesABrokenGameWithItsReason() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-loadtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = ShellHostModel(documents: workspace, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        model.testLoad(InstalledGame(titleID: TitleID("0100111000200000")!, directory: workspace,
                                     problem: NXPocketError(.packageDamaged, "damaged on purpose")))
        guard case .failed(let message) = model.loadTest else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("damaged on purpose"), message)
        model.clearLoadTest()
        XCTAssertEqual(model.loadTest, .idle)
    }

    @MainActor
    func testLoadTestNeedsNoEngineButACertificate() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-loadtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let model = ShellHostModel(documents: workspace, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        guard model.signingIdentity == nil else { throw XCTSkip("a certificate is installed in this keychain") }
        model.language = "en"
        model.testLoad(InstalledGame(titleID: TitleID("0100111000200000")!, directory: workspace))
        guard case .failed(let message) = model.loadTest else { return XCTFail("expected a refusal") }
        XCTAssertFalse(message.contains("engine"), "the load test must not need the engine: \(message)")
        XCTAssertTrue(message.lowercased().contains("certificate"), message)
    }

    func testLoadReportPassesOnlyWithTheMarkerAndEveryModulesSections() {
        // The first real game's layout: two modules, three 16K-aligned sections each.
        func module(_ name: String, x1Aligned: Bool = true, w: Int? = 0x223c000) -> LoadTestReport.Module {
            LoadTestReport.Module(name: name, sections: [.init(name: "__dm\(name)x0", size: 0xb84000, aligned: true),
                                                         .init(name: "__DM\(name)W", size: w, aligned: w != nil),
                                                         .init(name: "__dm\(name)x1", size: 0x74000, aligned: x1Aligned)])
        }
        var report = LoadTestReport(signingSeconds: 12.5, executableBytes: 200 * 1_048_576, loadSeconds: 0.042,
                                    markerFound: true, marker: "dmgame_image_marker",
                                    modules: [module("main"), module("sdk")],
                                    availableBefore: 6_000_000_000, availableAfter: 5_700_000_000)
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("signed: 12.5 s") && $0.contains("16.0 MB/s") }, "\(report.lines)")
        XCTAssertTrue(report.lines.contains("loaded from Documents in 42 ms"))
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("module main: __dmmainx0") && $0.hasSuffix("all 16K-aligned") },
                      "\(report.lines)")
        XCTAssertTrue(report.lines.last?.hasPrefix("RESULT: the game loads") == true)

        report.signingSeconds = nil
        XCTAssertTrue(report.lines.first?.hasPrefix("signed: already") == true)

        report.markerFound = false
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.lines.contains { $0.contains("MISSING, the loaded image is not this game's code") })

        report.markerFound = true
        report.modules = [module("main"), module("sdk", x1Aligned: false)]
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("module sdk:") && $0.hasSuffix("NOT 16K-aligned") }, "\(report.lines)")
        report.modules = [module("main", w: nil)]
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.lines.contains { $0.contains("__DMmainW MISSING") }, "\(report.lines)")
        report.modules = []
        XCTAssertFalse(report.passed, "a manifest that names no module proves nothing")
    }
}

final class ProvisioningProfileTests: XCTestCase {
    /// SideStore renews the profile every 7 days; a new certificate in it means the imported .p12 is stale.
    func testTellsWhetherACertificateIsInTheProfile() throws {
        let current = Data("certificate SideStore signs with now".utf8)
        let profile: [String: Any] = ["DeveloperCertificates": [current, Data("an older one".utf8)]]
        let hashes = try XCTUnwrap(ProvisioningProfile.certificateHashes(in: profile))
        XCTAssertTrue(hashes.contains(FileDigest.sha256(of: current)))
        XCTAssertFalse(hashes.contains(FileDigest.sha256(of: Data("the .p12 imported last week".utf8))))
        XCTAssertNil(ProvisioningProfile.certificateHashes(in: nil), "no profile, no answer")
    }
}

final class FrameworkLoaderTests: XCTestCase {
    /// dladdr on a dlopen handle always fails under dyld4, which is what stopped the first real game's load test after
    /// dlopen had succeeded. This test bundle is an image dyld loaded from a file, as a game's framework is, so loading
    /// it again has to find that image and its header.
    func testFindsTheImageItLoadedByItsFile() throws {
        let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        let framework = try FrameworkLoader.load(executable: executable)
        XCTAssertEqual(framework.imageBase, UnsafeRawPointer(#dsohandle))
        XCTAssertEqual(framework.path, executable.path)
    }

    // MARK: - Starting a game (FrameworkEngineHost)

    @MainActor
    func testAnImageWithoutTheMarkerIsRefusedAsDamaged() throws {
        let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        guard case .failure(let error) = FrameworkEngineHost.resolve(executable: executable.path,
                                                                       marker: "nxpocket_no_such_marker") else {
            return XCTFail("an image without the marker must be refused")
        }
        XCTAssertTrue(error.message.contains("no nxpocket_no_such_marker symbol"), error.message)
    }

    @MainActor
    func testAFrameworkWithoutTheGlueIsRefusedWithTheVersionsCompared() {
        // libz has a symbol to stand for the marker and none of the four entry points: a framework built without
        // its host looks exactly so. It is named by the file dyld loads it from (the simulator's runtime root), as a
        // game's framework is: the marker has to lie in the file the start names.
        var info = Dl_info()
        guard let handle = dlopen("/usr/lib/libz.1.dylib", RTLD_LAZY), let symbol = dlsym(handle, "zlibVersion"),
              dladdr(symbol, &info) != 0, let file = info.dli_fname else { return XCTFail("libz is not there") }
        guard case .failure(let error) = FrameworkEngineHost.resolve(executable: String(cString: file),
                                                                       marker: "zlibVersion") else {
            return XCTFail("an image without the glue must be refused")
        }
        XCTAssertTrue(error.message.contains("built without its host (glue version 0, expected 1)"), error.message)
    }

    @MainActor
    func testAFileThatDoesNotLoadIsRefusedWithDyldsWords() {
        guard case .failure(let error) = FrameworkEngineHost.resolve(executable: "/nonexistent/DmGame", marker: "m") else {
            return XCTFail("a missing file must be refused")
        }
        XCTAssertTrue(error.message.hasPrefix("The game's code could not be loaded: "), error.message)
    }

    @MainActor
    func testTheArgumentsReachTheFrameworkNullTerminated() {
        let seen = FrameworkEngineHost.withCStrings(["dmhost", "/x/dm", "main"]) { argv -> [String?] in
            (0..<4).map { argv[$0].map { String(cString: $0) } }
        }
        XCTAssertEqual(seen, ["dmhost", "/x/dm", "main", nil])
    }

    func testTheMetalHUDIsReadiedUnlessTheLaunchSetIt() {
        let saved = (getenv("MTL_HUD_ENABLED").map { String(cString: $0) }, getenv("DM_HUD_PER_LAYER").map { String(cString: $0) })
        defer {
            if let value = saved.0 { setenv("MTL_HUD_ENABLED", value, 1) } else { unsetenv("MTL_HUD_ENABLED") }
            if let value = saved.1 { setenv("DM_HUD_PER_LAYER", value, 1) } else { unsetenv("DM_HUD_PER_LAYER") }
        }
        unsetenv("MTL_HUD_ENABLED"); unsetenv("DM_HUD_PER_LAYER")
        FrameworkEngineHost.prepareProcess()
        XCTAssertEqual(getenv("MTL_HUD_ENABLED").map { String(cString: $0) }, "1")
        XCTAssertEqual(getenv("DM_HUD_PER_LAYER").map { String(cString: $0) }, "1")

        setenv("MTL_HUD_ENABLED", "0", 1); unsetenv("DM_HUD_PER_LAYER")
        FrameworkEngineHost.prepareProcess()
        XCTAssertEqual(getenv("MTL_HUD_ENABLED").map { String(cString: $0) }, "0", "a value given at launch wins")
        XCTAssertNil(getenv("DM_HUD_PER_LAYER"))
    }

    func testReadsTheSectionsTheEngineMapsForEachModule() throws {
        let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        let framework = try FrameworkLoader.load(executable: executable)
        XCTAssertNotNil(FrameworkLoader.section(of: framework, "__TEXT", "__text", aligned: false).size,
                        "a section the image has is found")
        let modules = FrameworkLoader.moduleSections(of: framework, modules: ["main"], nroCount: 2)
        XCTAssertEqual(modules.map(\.name), ["main", "NROs (2)"])
        XCTAssertEqual(modules.first?.sections.map(\.name), ["__dmmainx0", "__DMmainW", "__dmmainx1"])
        XCTAssertTrue(modules.allSatisfy { !$0.isUsable }, "this test bundle embeds no game")
    }

    func testAFileThatDoesNotLoadIsRefusedWithDyldsReason() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nxpocket-missing-\(UUID().uuidString)/DmGame0100111000200000")
        XCTAssertThrowsError(try FrameworkLoader.load(executable: missing)) { error in
            guard let error = error as? NXPocketError else { return XCTFail("\(error)") }
            XCTAssertEqual(error.code, .notSigned)
            XCTAssertTrue(error.detail.hasPrefix("dlopen refused DmGame0100111000200000: "), error.detail)
        }
    }
}

/// Accepts whatever it is handed, for the parts of the import that are not about zsign.
struct AcceptingSigner: FrameworkSigner {
    func sign(framework: URL, identity: SigningIdentity) throws -> CodeSignatureInfo {
        CodeSignatureInfo(identifier: identity.identifier, teamID: identity.teamID, flags: 0, hasCertificate: true,
                          signerName: identity.subject, codeDirectoryVersion: 0x20400, hashType: 2)
    }
}

/// A minimal arm64 iOS dylib, built here rather than committed: the repository holds no binary.
enum SyntheticMachO {
    static func dylib() -> Data {
        var commands = Data()
        let name = "@rpath/DmGame"
        let body = 24 + name.utf8.count + 1
        let size = (body + 7) / 8 * 8
        commands.append(le32(0x0C)); commands.append(le32(UInt32(size)))
        commands.append(le32(24)); commands.append(le32(0))
        commands.append(le32(0x10000)); commands.append(le32(0x10000))
        commands.append(contentsOf: Array(name.utf8) + [0])
        commands.append(contentsOf: [UInt8](repeating: 0, count: size - body))

        var build = Data()
        build.append(le32(0x32)); build.append(le32(24))
        build.append(le32(MachOFile.BuildVersion.platformIOS))
        build.append(le32(UInt32(26) << 16))
        build.append(le32(UInt32(27) << 16 | 2))
        build.append(le32(0))
        commands.append(build)

        var header = Data()
        header.append(le32(MachOFile.magic64))
        header.append(le32(UInt32(bitPattern: MachOFile.cpuTypeARM64)))
        header.append(le32(0))
        header.append(le32(MachOFile.fileTypeDylib))
        header.append(le32(2))
        header.append(le32(UInt32(commands.count)))
        header.append(le32(0x0020_0085))
        header.append(le32(0))
        return header + commands
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
