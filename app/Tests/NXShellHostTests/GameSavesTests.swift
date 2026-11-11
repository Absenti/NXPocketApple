import NXPocketKit
import XCTest

@testable import NXShellHost

/// A game on disk that `GameLibrary` lists, with saves: `save/slot1.bin` and `save_meta.dat`.
struct LibraryFixture {
    static let titleID = "0100111000200000"
    let documents: URL

    init() throws {
        documents = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-library-\(UUID().uuidString)")
        let folder = documents.appendingPathComponent("games/\(Self.titleID)", isDirectory: true)
        let framework = folder.appendingPathComponent("DmGame\(Self.titleID).framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["schema": 1, "title_id": Self.titleID, "name": "Fixture", "display_version": "1.0.0",
                                       "package_version": "65536", "modules": ["main"], "nro_count": 0, "chain": "b-3f9a2c",
                                       "loader": "FH", "framework": "DmGame\(Self.titleID).framework",
                                       "framework_executable": "DmGame\(Self.titleID)", "image_marker": "dmgame_image_marker",
                                       "profile": "profile.tsv", "shader_map": "dm/shader_map.tsv", "launcher": "dm/launcher.json", "romfs_marker": "r",
                                       "romfs_identity": "i", "min_os": "26.0"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: framework.appendingPathComponent("game.manifest.json"))
        // The library lists a game whose code is missing as damaged: the fixture carries a stand-in executable.
        try Data("stand-in".utf8).write(to: framework.appendingPathComponent("DmGame\(Self.titleID)"))
        let package: [String: Any] = ["schema": 1, "title_id": Self.titleID, "name": "Fixture", "version": "1.0.0",
                                      "package_version": "65536", "framework": "DmGame\(Self.titleID).framework",
                                      "chain": "b-3f9a2c", "min_os": "26.0", "romfs_id": "", "romfs_size": 0, "aoc_size": 0,
                                      "files": [], "created_by": "tests"]
        try JSONSerialization.data(withJSONObject: package).write(to: folder.appendingPathComponent("package.json"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("old slot".utf8).write(to: folder.appendingPathComponent("save/slot1.bin"))
        try Data("old meta".utf8).write(to: folder.appendingPathComponent("save_meta.dat"))
    }

    var folder: URL { documents.appendingPathComponent("games/\(Self.titleID)", isDirectory: true) }
    var game: InstalledGame { GameLibrary.entry(at: folder) }

    func text(_ relative: String, in root: URL? = nil) -> String? {
        FileManager.default.contents(atPath: (root ?? folder).appendingPathComponent(relative).path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A copy as the Mac's `SaveBackup` writes it: a dated folder with the `save*` entries and `backup.json`.
    func macCopy(titleID: String = titleID, slot: String = "new slot", files: Int? = 1, bytes: Int64? = nil) throws -> URL {
        let copy = documents.appendingPathComponent("picked/2026-11-10 120000", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data(slot.utf8).write(to: copy.appendingPathComponent("save/slot1.bin"))
        var manifest: [String: Any] = ["title_id": titleID, "name": "Fixture", "device": "iPhone", "created": "2026-11-10T12:00:00Z"]
        if let files { manifest["files"] = files }
        manifest["bytes"] = bytes ?? Int64(slot.utf8.count)
        try JSONSerialization.data(withJSONObject: manifest).write(to: copy.appendingPathComponent(GameSaves.manifestName))
        return copy
    }

    func remove() { try? FileManager.default.removeItem(at: documents) }
}

final class GameSavesTests: XCTestCase {
    private var fixture: LibraryFixture!
    private var staging: URL { fixture.documents.appendingPathComponent(".saves-test", isDirectory: true) }

    override func setUpWithError() throws { fixture = try LibraryFixture() }
    override func tearDown() { fixture.remove() }

    func testAnExportIsOneZipHoldingTheDatedFolderAMacCopyIs() throws {
        let temporary = fixture.documents.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let now = try XCTUnwrap(GameSaves.stamp.date(from: "2026-11-11 153000"))
        let zip = try GameSaves.export(fixture.game, name: "South Park: Fixture", device: "iPhone", temporary: temporary, now: now)
        XCTAssertEqual(zip.lastPathComponent, "South Park Fixture 2026-11-11 153000.zip", "no colon in a file name")
        XCTAssertTrue(SaveArchive.isZip(zip))

        let unzipped = fixture.documents.appendingPathComponent("unzipped", isDirectory: true)
        try SaveArchive.extract(zip, into: unzipped)
        let folder = unzipped.appendingPathComponent("2026-11-11 153000", isDirectory: true)
        XCTAssertEqual(fixture.text("save/slot1.bin", in: folder), "old slot")
        XCTAssertEqual(fixture.text("save_meta.dat", in: folder), "old meta")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(GameSaves.manifestName))) as? [String: Any])
        XCTAssertEqual(manifest["title_id"] as? String, LibraryFixture.titleID)
        XCTAssertEqual(manifest["files"] as? Int, 2)
        XCTAssertEqual((manifest["bytes"] as? NSNumber)?.int64Value, 16)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), [zip.lastPathComponent],
                       "the staging copy is gone")
    }

    func testAnExportedZipImportsBackIntoTheSameGame() throws {
        let temporary = fixture.documents.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let zip = try GameSaves.export(fixture.game, name: "Fixture", device: "iPhone", temporary: temporary)
        let copy = try GameSaves.read(zip, for: LibraryFixture.titleID, staging: staging)
        XCTAssertEqual(copy.entries, ["save", "save_meta.dat"])
        XCTAssertEqual(copy.name, "Fixture")
    }

    func testAMacCopyReplacesTheSavesAndTheReplacedOnesAreKeptInTheSameLayout() throws {
        let copy = try GameSaves.read(try fixture.macCopy(), for: LibraryFixture.titleID, staging: staging)
        let kept = try XCTUnwrap(try GameSaves.restore(copy, into: fixture.game, name: "Fixture", documents: fixture.documents,
                                                       device: "iPhone"))
        XCTAssertEqual(fixture.text("save/slot1.bin"), "new slot")
        XCTAssertNil(fixture.text("save_meta.dat"), "an entry the copy does not have goes: the copy is the whole save")
        XCTAssertEqual(kept.deletingLastPathComponent(), GameSaves.keptFolder(titleID: LibraryFixture.titleID, documents: fixture.documents))
        XCTAssertEqual(fixture.text("save/slot1.bin", in: kept), "old slot")
        XCTAssertEqual(fixture.text("save_meta.dat", in: kept), "old meta")
        XCTAssertNotNil(fixture.text(GameSaves.manifestName, in: kept), "the kept copy can be imported back")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).filter { $0.hasPrefix(".saves-") }, [])
    }

    func testTheKeptCopyImportsBack() throws {
        let copy = try GameSaves.read(try fixture.macCopy(), for: LibraryFixture.titleID, staging: staging)
        let kept = try XCTUnwrap(try GameSaves.restore(copy, into: fixture.game, name: "Fixture", documents: fixture.documents,
                                                       device: "iPhone"))
        let back = try GameSaves.read(kept, for: LibraryFixture.titleID,
                                      staging: fixture.documents.appendingPathComponent(".saves-back"))
        try GameSaves.restore(back, into: fixture.game, name: "Fixture", documents: fixture.documents, device: "iPhone")
        XCTAssertEqual(fixture.text("save/slot1.bin"), "old slot")
        XCTAssertEqual(fixture.text("save_meta.dat"), "old meta")
    }

    func testASaveOfAnotherGameIsRefusedAndTheSavesStay() throws {
        let other = try fixture.macCopy(titleID: "0100222000300000")
        XCTAssertThrowsError(try GameSaves.read(other, for: LibraryFixture.titleID, staging: staging)) { error in
            XCTAssertEqual(error as? SaveProblem, .otherGame(titleID: "0100222000300000", name: "Fixture"))
        }
        XCTAssertEqual(fixture.text("save/slot1.bin"), "old slot")
    }

    func testACopyWithFewerFilesThanItsBackupJsonCountsIsIncomplete() throws {
        XCTAssertThrowsError(try GameSaves.read(try fixture.macCopy(files: 3), for: LibraryFixture.titleID, staging: staging)) {
            XCTAssertEqual($0 as? SaveProblem, .incomplete)
        }
    }

    func testAFolderWithoutBackupJsonIsNotACopy() throws {
        let folder = fixture.documents.appendingPathComponent("loose/save", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("slot1.bin"))
        XCTAssertThrowsError(try GameSaves.read(folder.deletingLastPathComponent(), for: LibraryFixture.titleID, staging: staging)) {
            XCTAssertEqual($0 as? SaveProblem, .notACopy)
        }
    }

    func testAGameWithNoSaveHasNothingToExport() throws {
        try GameSaves.delete(in: fixture.game)
        XCTAssertEqual(GameSaves.entries(in: fixture.folder), [])
        XCTAssertNotNil(fixture.game.package, "the game itself stays")
        XCTAssertThrowsError(try GameSaves.export(fixture.game, name: "Fixture", device: "iPhone",
                                                  temporary: fixture.documents)) {
            XCTAssertEqual($0 as? SaveProblem, .noSaves)
        }
    }

    func testOnlyTheTenNewestKeptCopiesStay() throws {
        let parent = GameSaves.keptFolder(titleID: LibraryFixture.titleID, documents: fixture.documents)
        for day in 1...12 {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(String(format: "2026-10-%02d 120000", day)),
                                                    withIntermediateDirectories: true)
        }
        GameSaves.rotate(parent, fileManager: .default)
        let left = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        XCTAssertEqual(left.count, 10)
        XCTAssertEqual(left.first, "2026-10-03 120000")
    }
}

final class SaveArchiveTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testFindersLeftoversAreLeftOutAndStoredEntriesRead() throws {
        let zip = folder.appendingPathComponent("finder.zip")
        try StoredZip.write([("copy/backup.json", Data("{}".utf8)), ("copy/save/a.bin", Data("abc".utf8)),
                             ("__MACOSX/copy/._backup.json", Data("rsrc".utf8)), ("copy/.DS_Store", Data("ds".utf8))], to: zip)
        let out = folder.appendingPathComponent("out")
        try SaveArchive.extract(zip, into: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("copy/save/a.bin")), Data("abc".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("__MACOSX").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("copy/.DS_Store").path))
    }

    func testAnEntryThatWouldLeaveTheFolderIsRefused() throws {
        let zip = folder.appendingPathComponent("escape.zip")
        try StoredZip.write([("../escape.bin", Data("x".utf8))], to: zip)
        XCTAssertThrowsError(try SaveArchive.extract(zip, into: folder.appendingPathComponent("out")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("escape.bin").path))
    }

    func testADamagedEntryFailsItsChecksum() throws {
        let zip = folder.appendingPathComponent("damaged.zip")
        try StoredZip.write([("save/a.bin", Data("abcdef".utf8))], to: zip)
        var bytes = try Data(contentsOf: zip)
        let at = try XCTUnwrap(bytes.range(of: Data("abcdef".utf8))).lowerBound
        bytes[at] = UInt8(ascii: "z")
        try bytes.write(to: zip)
        XCTAssertThrowsError(try SaveArchive.extract(zip, into: folder.appendingPathComponent("out"))) {
            guard case SaveArchive.Failure.damaged = $0 else { return XCTFail("\($0)") }
        }
    }

    func testTheChecksumIsTheZipFormatsOne() {
        XCTAssertEqual(Data("123456789".utf8).withUnsafeBytes(CRC32.checksum), 0xCBF4_3926)
    }
}

/// A .zip with stored entries, written by hand: what the reader must accept besides the system's deflated ones.
enum StoredZip {
    static func write(_ entries: [(String, Data)], to url: URL) throws {
        var out = Data()
        var central = Data()
        for (name, data) in entries {
            let offset = UInt32(out.count)
            let crc = data.withUnsafeBytes(CRC32.checksum)
            let nameBytes = Data(name.utf8)
            let size = UInt32(data.count)
            let local: [Data] = [le32(0x0403_4B50), le16(20), le16(0x0800), le16(0), le16(0), le16(0), le32(crc),
                                 le32(size), le32(size), le16(UInt16(nameBytes.count)), le16(0), nameBytes, data]
            out.append(contentsOf: local.joined())
            let entry: [Data] = [le32(0x0201_4B50), le16(0x031E), le16(20), le16(0x0800), le16(0), le16(0), le16(0),
                                 le32(crc), le32(size), le32(size), le16(UInt16(nameBytes.count)), le16(0), le16(0),
                                 le16(0), le16(0), le32(0o100644 << 16), le32(offset), nameBytes]
            central.append(contentsOf: entry.joined())
        }
        let start = UInt32(out.count)
        out.append(central)
        let end: [Data] = [le32(0x0605_4B50), le16(0), le16(0), le16(UInt16(entries.count)), le16(UInt16(entries.count)),
                           le32(UInt32(central.count)), le32(start), le16(0)]
        out.append(contentsOf: end.joined())
        try out.write(to: url)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
