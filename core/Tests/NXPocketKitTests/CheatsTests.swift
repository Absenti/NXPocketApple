import XCTest

@testable import NXPocketKit

/// Cheat files as the engine reads them, and the small files a front end writes around them.
final class CheatsTests: XCTestCase {
    private let titleID = "0100111000200000"
    private let build = "2C336A9BCF79C304"
    private var documents: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        documents = fileManager.temporaryDirectory.appendingPathComponent("nxpocket-cheats-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDown() { try? fileManager.removeItem(at: documents) }

    private func file(_ text: String, named: String = "cheats.txt") throws -> URL {
        let url = documents.appendingPathComponent(named)
        try Data(text.utf8).write(to: url)
        return url
    }

    private let sample = "{Master code}\n04000000 00123456 00000001\n\n[Max HP]\n04000000 00123456 000003E7\n"

    // MARK: the grammar

    func testACheatFileIsReadAsTheEngineReadsIt() throws {
        let text = "{Master}\n580F0000 0000ABCD\n[Max HP]\n04000000 00123456 000003E7\n\n[Infinite items]\n0400000000123456 00000063\n"
        let entries = try Cheats.parse(Data(text.utf8))
        XCTAssertEqual(entries.map(\.name), ["Master", "Max HP", "Infinite items"])
        XCTAssertEqual(entries.map(\.isMaster), [true, false, false])
        XCTAssertEqual(entries.map(\.words), [2, 3, 3], "a run of 16 digits is two words")
    }

    func testALabelWithNoCodeIsNotACheatAndARepeatedNameIsNumbered() throws {
        let entries = try Cheats.parse(Data("[--- Health ---]\n[Max HP]\n00000000\n[Max HP]\n00000001\n[Max HP]\n00000002\n".utf8))
        XCTAssertEqual(entries.map(\.name), ["Max HP", "Max HP #2", "Max HP #3"])
    }

    func testWhatTheEngineRefusesIsRefusedWithTheLine() {
        func problem(_ text: String) -> Cheats.Problem? {
            do { _ = try Cheats.parse(Data(text.utf8)); return nil } catch { return error as? Cheats.Problem }
        }
        XCTAssertEqual(problem("[A]\n0400000\n")?.line, 2, "hex digits that are not whole words")
        XCTAssertEqual(problem("[A]\ndead beef\n")?.line, 2, "two short tokens are not a word")
        XCTAssertEqual(problem("04000000\n")?.line, 1, "a code before any name")
        XCTAssertEqual(problem("[A]\n# a comment\n04000000\n")?.line, 2, "there is no comment syntax")
        XCTAssertEqual(problem("[A\n04000000\n")?.line, 1, "a name that is not closed")
        XCTAssertNotNil(problem("{A}\n00000000\n{B}\n00000000\n"), "two masters")
        XCTAssertNotNil(problem("[\(String(repeating: "x", count: 70))]\n00000000\n"), "a name over 63 bytes")
        XCTAssertNotNil(problem("[A]\n" + String(repeating: "00000000 ", count: 0x101)), "more than 0x100 words")
        XCTAssertNotNil(problem((1...128).map { "[C\($0)]\n00000000\n" }.joined()), "more than 127 cheats")
        XCTAssertNil(problem("\u{FEFF}[A]\r\n04000000\r\n"), "a file made on Windows is fine")
        XCTAssertThrowsError(try Cheats.parse(Data(count: 70_000)))
        XCTAssertThrowsError(try Cheats.parse(Data([0xFF, 0xFE, 0x00])))
    }

    // MARK: the build

    func testTheBuildIDIsReadFromWhatTheBuildWrote() throws {
        let framework = documents.appendingPathComponent("DmGame.framework", isDirectory: true)
        try fileManager.createDirectory(at: framework.appendingPathComponent("dm"), withIntermediateDirectories: true)
        try Data("# PATCH_OFF\t0x1370000\n# BUILD_ID\t2c336a9bcf79c3040ce506cdd391b578\n".utf8).write(to: framework.appendingPathComponent("dm/main.fixups.tsv"))
        XCTAssertEqual(Cheats.buildID(inFramework: framework), "2C336A9BCF79C304", "the first eight bytes, in capitals, as cheat sites name their files")
        try Data("# NOPE\n".utf8).write(to: framework.appendingPathComponent("dm/main.fixups.tsv"))
        XCTAssertNil(Cheats.buildID(inFramework: framework))
        XCTAssertNil(Cheats.buildID(inFramework: documents.appendingPathComponent("nowhere")))
    }

    // MARK: keeping a file and its switches

    func testAFileIsCheckedKeptOutsideTheGameAndStartsWithNothingOn() throws {
        let entries = try Cheats.install(try file(sample), titleID: titleID, buildID: build, documents: documents)
        XCTAssertEqual(entries.map(\.name), ["Master code", "Max HP"])
        XCTAssertTrue(fileManager.fileExists(atPath: documents.appendingPathComponent("Cheats/\(titleID)/\(build).txt").path),
                      "in Documents/Cheats, not in the game's folder that an update replaces")
        XCTAssertEqual(Cheats.installed(titleID: titleID, buildID: build, documents: documents)?.count, 2)
        XCTAssertTrue(Cheats.enabled(titleID: titleID, buildID: build, documents: documents).isEmpty)
        XCTAssertFalse(Cheats.isActive(titleID: titleID, buildID: build, documents: documents))
    }

    func testABadFileIsRefusedAndNothingIsKept() throws {
        XCTAssertThrowsError(try Cheats.install(try file("[A]\nnot hex\n"), titleID: titleID, buildID: build, documents: documents))
        XCTAssertThrowsError(try Cheats.install(try file("just words"), titleID: titleID, buildID: build, documents: documents))
        XCTAssertThrowsError(try Cheats.install(try file("[Label]\n"), titleID: titleID, buildID: build, documents: documents), "no cheat in it")
        XCTAssertFalse(fileManager.fileExists(atPath: documents.appendingPathComponent("Cheats").path))
    }

    func testANewFileKeepsTheOldOneAsBakAndForgetsWhatWasOn() throws {
        try Cheats.install(try file(sample), titleID: titleID, buildID: build, documents: documents)
        try Cheats.setEnabled(["Max HP"], titleID: titleID, buildID: build, documents: documents)
        try Cheats.install(try file("[Other]\n00000001\n", named: "two.txt"), titleID: titleID, buildID: build, documents: documents)
        let folder = documents.appendingPathComponent("Cheats/\(titleID)")
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("\(build).txt.bak").path))
        XCTAssertEqual(Cheats.installed(titleID: titleID, buildID: build, documents: documents)?.map(\.name), ["Other"])
        XCTAssertTrue(Cheats.enabled(titleID: titleID, buildID: build, documents: documents).isEmpty, "names of the old file mean nothing to the new one")
    }

    func testWhichCheatsAreOnIsWrittenAsTheEngineReadsIt() throws {
        try Cheats.install(try file(sample), titleID: titleID, buildID: build, documents: documents)
        try Cheats.setEnabled(["Max HP", "Max HP #2"], titleID: titleID, buildID: build, documents: documents)
        let text = try String(contentsOf: documents.appendingPathComponent("Cheats/\(titleID)/\(build).enabled"), encoding: .utf8)
        XCTAssertEqual(text, "Max HP\nMax HP #2\n", "one name per line")
        XCTAssertEqual(Cheats.enabled(titleID: titleID, buildID: build, documents: documents), ["Max HP", "Max HP #2"])
        XCTAssertTrue(Cheats.isActive(titleID: titleID, buildID: build, documents: documents))
        try Cheats.setEnabled([], titleID: titleID, buildID: build, documents: documents)
        XCTAssertFalse(Cheats.isActive(titleID: titleID, buildID: build, documents: documents))
    }

    func testTheMasterSwitchIsTheEnginesOwnFileAndTurnsEverythingOff() throws {
        try Cheats.install(try file(sample), titleID: titleID, buildID: build, documents: documents)
        try Cheats.setEnabled(["Max HP"], titleID: titleID, buildID: build, documents: documents)
        XCTAssertTrue(Cheats.isMasterOn(titleID: titleID, documents: documents))
        try Cheats.setMaster(false, titleID: titleID, documents: documents)
        XCTAssertTrue(fileManager.fileExists(atPath: documents.appendingPathComponent("Cheats/\(titleID)/.cheats-off-\(titleID)").path))
        XCTAssertFalse(Cheats.isActive(titleID: titleID, buildID: build, documents: documents), "toggles are kept, nothing runs")
        XCTAssertEqual(Cheats.enabled(titleID: titleID, buildID: build, documents: documents), ["Max HP"])
        try Cheats.setMaster(true, titleID: titleID, documents: documents)
        XCTAssertTrue(Cheats.isActive(titleID: titleID, buildID: build, documents: documents))
    }

    func testRemovingTheFileTakesItsSwitchesToo() throws {
        try Cheats.install(try file(sample), titleID: titleID, buildID: build, documents: documents)
        try Cheats.setEnabled(["Max HP"], titleID: titleID, buildID: build, documents: documents)
        Cheats.remove(titleID: titleID, buildID: build, documents: documents)
        XCTAssertNil(Cheats.installed(titleID: titleID, buildID: build, documents: documents))
        XCTAssertTrue(Cheats.enabled(titleID: titleID, buildID: build, documents: documents).isEmpty)
    }
}
