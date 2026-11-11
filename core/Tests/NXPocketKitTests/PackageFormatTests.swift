import XCTest

@testable import NXPocketKit

final class TitleIDTests: XCTestCase {
    func testParsesBothCases() {
        XCTAssertEqual(TitleID("0100111000200000")?.rawValue, 0x0100_1110_0020_0000)
        XCTAssertEqual(TitleID("0100abcd00200000")?.description, "0100ABCD00200000")
    }

    func testRejectsWrongShapes() {
        XCTAssertNil(TitleID("010011100020000"))
        XCTAssertNil(TitleID("01001110002000000"))
        XCTAssertNil(TitleID("01001110002zz000"))
        XCTAssertNil(TitleID(""))
    }

    func testClassifiesUpdatesAndDlc() {
        XCTAssertEqual(TitleID("0100111000200000")?.kind, .application)
        XCTAssertEqual(TitleID("0100111000200800")?.kind, .update)
        XCTAssertEqual(TitleID("0100111000201001")?.kind, .other)
        XCTAssertEqual(TitleID("0100111000200800")?.baseApplication.description, "0100111000200000")
        XCTAssertEqual(TitleID("0100152000022000")?.baseApplication.description, "0100152000022000")
    }

    func testIsGameRequiresTheApplicationPrefix() {
        XCTAssertTrue(TitleID.isGame("0100111000200000"))
        XCTAssertFalse(TitleID.isGame("0100111000200800"))
        XCTAssertFalse(TitleID.isGame("0200111000200000"))
    }
}

final class OSVersionTests: XCTestCase {
    func testParsesAndOrders() {
        XCTAssertEqual(OSVersion("26.0"), OSVersion(major: 26, minor: 0))
        XCTAssertEqual(OSVersion("26.4.1"), OSVersion(major: 26, minor: 4, patch: 1))
        XCTAssertNil(OSVersion("26.0.0.1"))
        XCTAssertNil(OSVersion("x"))
        XCTAssertLessThan(OSVersion(major: 26, minor: 0), OSVersion(major: 27, minor: 0))
        XCTAssertEqual(OSVersion(major: 26, minor: 0).description, "26.0")
    }
}

final class GamePackageTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let package = GamePackage(titleID: TitleID("0100111000200000")!, name: "Game", version: "1.0.0",
                                  packageVersion: "65536", framework: "DmGame0100111000200000.framework",
                                  chain: "b-3f9a2c", minOS: "26.0", romfsID: "DMROMFSID1 size=1 index=2",
                                  romfsSize: 10, aocSize: 0,
                                  files: [.init(path: "DmGame", size: 3, sha256: String(repeating: "b", count: 64))],
                                  createdBy: "nxpocket-tests")
        let decoded = try GamePackage.decode(try package.data())
        XCTAssertEqual(decoded, package)
        XCTAssertEqual(decoded.totalSize, 13)
    }

    func testUsesTheDocumentedKeyNames() throws {
        let package = GamePackage(titleID: TitleID("0100111000200000")!, name: "Game", version: "1.0.0",
                                  packageVersion: "65536", framework: "DmGame.framework", chain: "b-3f9a2c",
                                  minOS: "26.0", romfsID: "DMROMFSID1", romfsSize: 0, aocSize: 0,
                                  files: [], createdBy: "nxpocket-tests")
        let json = try JSONSerialization.jsonObject(with: try package.data()) as? [String: Any]
        XCTAssertEqual(json?["title_id"] as? String, "0100111000200000")
        XCTAssertEqual(json?["min_os"] as? String, "26.0")
        XCTAssertEqual(json?["package_version"] as? String, "65536")
        XCTAssertEqual(json?["created_by"] as? String, "nxpocket-tests")
        XCTAssertNotNil(json?["files"])
    }

    func testRefusesAMissingKey() {
        XCTAssertThrowsError(try GamePackage.decode(Data(#"{"schema":1}"#.utf8))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageDamaged)
        }
    }
}

final class GameManifestTests: XCTestCase {
    func testReadsTheEngineSchema() throws {
        let json = """
        {"schema":1,"title_id":"0100000000030000","name":"Game","display_version":"1.0.0","package_version":"65536",
         "modules":["main"],"nro_count":0,"chain":"b-3f9a2c","loader":"FR","framework":"DmGame.framework",
         "framework_executable":"DmGame","image_marker":"m","profile":"p.tsv","shader_map":"s.tsv",
         "launcher":"dm/launcher.json","romfs_marker":"r","romfs_identity":"i","min_os":"26.0"}
        """
        let manifest = try GameManifest.decode(Data(json.utf8))
        XCTAssertEqual(manifest.titleID, "0100000000030000")
        XCTAssertEqual(manifest.minOSVersion, OSVersion(major: 26, minor: 0))
        XCTAssertEqual(manifest.frameworkExecutable, "DmGame")
    }

    func testRefusesAnotherSchema() {
        let json = #"{"schema":2,"title_id":"0100000000030000","name":"G","display_version":"1","package_version":"1","modules":[],"nro_count":0,"chain":"b-3f9a2c","loader":"FR","framework":"D.framework","framework_executable":"D","image_marker":"m","profile":"p","shader_map":"s","launcher":"l","romfs_marker":"r","romfs_identity":"i","min_os":"26.0"}"#
        XCTAssertThrowsError(try GameManifest.decode(Data(json.utf8))) { error in
            XCTAssertEqual((error as? NXPocketError)?.code, .packageUnsupported)
        }
    }
}

final class SafePathTests: XCTestCase {
    func testAcceptsPlainRelativePaths() {
        XCTAssertTrue(SafePath.isSafeRelative("DmGame"))
        XCTAssertTrue(SafePath.isSafeRelative("dm/shader_map.tsv"))
    }

    func testRefusesEscapesAndSpecials() {
        XCTAssertFalse(SafePath.isSafeRelative("/etc/passwd"))
        XCTAssertFalse(SafePath.isSafeRelative("../escape"))
        XCTAssertFalse(SafePath.isSafeRelative("dm/../../escape"))
        XCTAssertFalse(SafePath.isSafeRelative("./here"))
        XCTAssertFalse(SafePath.isSafeRelative("dm//double"))
        XCTAssertFalse(SafePath.isSafeRelative("~/.ssh"))
        XCTAssertFalse(SafePath.isSafeRelative(""))
        XCTAssertFalse(SafePath.isSafeRelative("dm\\windows"))
        XCTAssertFalse(SafePath.isSafeRelative(String(repeating: "a", count: 600)))
    }

    func testResolvesOnlyInsideTheRoot() throws {
        let workspace = try TestWorkspace()
        try workspace.write("root/inside.txt", "x")
        let root = workspace.url("root")
        XCTAssertNotNil(SafePath.resolve("inside.txt", under: root))
        XCTAssertNil(SafePath.resolve("../outside", under: root))
    }
}
