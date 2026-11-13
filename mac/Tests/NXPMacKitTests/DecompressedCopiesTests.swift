import XCTest
@testable import NXPMacKit
@testable import NXPMacModel

/// The `.nsp` / `.xci` the engine makes out of an `.nsz` / `.xcz` may go; the dump, the build and everything else may not.
final class DecompressedCopiesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decompressed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.root) }
    }

    private func write(_ path: String, bytes: Int = 10, in base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private func exists(_ path: String, in base: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (base ?? root).appendingPathComponent(path).path)
    }

    /// The layout of the user's own: dumps in a folder, the work folder beside them with links to the dumps in `inputs/`.
    private func layout() throws -> (work: URL, originals: [URL]) {
        let dumps = root.appendingPathComponent("dumps", isDirectory: true)
        try write("Fractured [01008F2005154000][v0].nsz", bytes: 900, in: dumps)
        try write("Fractured [01008F2005154800][v327680].nsz", bytes: 400, in: dumps)
        let work = dumps.appendingPathComponent("01008F2005154000_build", isDirectory: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        let originals = ["Fractured [01008F2005154000][v0].nsz", "Fractured [01008F2005154800][v327680].nsz"].map { dumps.appendingPathComponent($0) }
        for original in originals {
            try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("inputs/\(original.lastPathComponent)"), withDestinationURL: original)
        }
        return (work, originals)
    }

    func testTheDecompressedCopiesGoAndNothingElseDoes() throws {
        let (work, originals) = try layout()
        try write("nsp/Fractured [01008F2005154000][v0].nsp", bytes: 1400, in: work)
        try write("nsp/Fractured [01008F2005154800][v327680].nsp", bytes: 600, in: work)
        try write("extract/v327680/RomFS.img", bytes: 5000, in: work)
        try write("shader/cache/cas.db", bytes: 3000, in: work)
        try write("logs/build.log", bytes: 50, in: work)

        let result = DecompressedCopies.remove(in: work, keeping: originals)

        XCTAssertEqual(result.removed, ["Fractured [01008F2005154000][v0].nsp", "Fractured [01008F2005154800][v327680].nsp"])
        XCTAssertEqual(result.bytes, 2000)
        XCTAssertFalse(exists("nsp", in: work), "the folder goes when nothing is left in it")
        for original in originals { XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "the dump \(original.lastPathComponent)") }
        XCTAssertEqual(try Data(contentsOf: originals[0]).count, 900, "the dump is byte for byte what it was")
        XCTAssertTrue(exists("extract/v327680/RomFS.img", in: work), "the extraction is not the decompressed copy")
        XCTAssertTrue(exists("shader/cache/cas.db", in: work))
        XCTAssertTrue(exists("logs/build.log", in: work))
        XCTAssertTrue(exists("inputs/Fractured [01008F2005154000][v0].nsz", in: work), "the links to the dumps")
    }

    func testAnXciCopyGoesToo() throws {
        let (work, originals) = try layout()
        try write("nsp/Game [0100AAAA00010000][v0].XCI", bytes: 800, in: work)
        XCTAssertEqual(DecompressedCopies.remove(in: work, keeping: originals).removed, ["Game [0100AAAA00010000][v0].XCI"])
    }

    /// A user who keeps a dump where the engine keeps its copies: it is one of the build's inputs, so it stays.
    func testAnInputIsNeverRemovedEvenInsideTheNspFolder() throws {
        let work = root.appendingPathComponent("0100AAAA00010000_build", isDirectory: true)
        try write("nsp/Mine [0100AAAA00010000][v0].nsp", bytes: 500, in: work)
        try write("nsp/Made [0100AAAA00010000][v1].nsp", bytes: 300, in: work)
        let mine = work.appendingPathComponent("nsp/Mine [0100AAAA00010000][v0].nsp")
        let result = DecompressedCopies.remove(in: work, keeping: [mine])
        XCTAssertEqual(result.removed, ["Made [0100AAAA00010000][v1].nsp"])
        XCTAssertTrue(exists("nsp/Mine [0100AAAA00010000][v0].nsp", in: work))
        XCTAssertTrue(exists("nsp", in: work), "something is left in it, so it stays")
    }

    func testALinkInTheNspFolderIsLeftAloneAndItsTargetToo() throws {
        let (work, originals) = try layout()
        try write("keep/real.nsp", bytes: 700)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("nsp"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("nsp/link.nsp"),
                                                   withDestinationURL: root.appendingPathComponent("keep/real.nsp"))
        XCTAssertTrue(DecompressedCopies.remove(in: work, keeping: originals).isEmpty)
        XCTAssertTrue(exists("nsp/link.nsp", in: work))
        XCTAssertTrue(exists("keep/real.nsp"))
    }

    func testOnlyNspAndXciFilesAreCopies() throws {
        let (work, originals) = try layout()
        try write("nsp/convert.log", bytes: 20, in: work)
        try write("nsp/notes.txt", bytes: 20, in: work)
        try write("nsp/sub/inner.nsp", bytes: 20, in: work)
        try write("nsp/Game [0100AAAA00010000][v0].nsp", bytes: 20, in: work)
        let result = DecompressedCopies.remove(in: work, keeping: originals)
        XCTAssertEqual(result.removed, ["Game [0100AAAA00010000][v0].nsp"])
        XCTAssertTrue(exists("nsp/convert.log", in: work))
        XCTAssertTrue(exists("nsp/notes.txt", in: work))
        XCTAssertTrue(exists("nsp/sub/inner.nsp", in: work), "a folder is not a copy: nothing inside it is looked at")
    }

    func testNothingToRemoveForADumpThatWasNotCompressed() throws {
        let (work, originals) = try layout()
        XCTAssertTrue(DecompressedCopies.remove(in: work, keeping: originals).isEmpty, "no nsp folder at all")
    }

    func testAFolderThatIsNotABuildFolderIsNeverTouched() throws {
        let other = root.appendingPathComponent("Documents", isDirectory: true)
        try write("nsp/precious.nsp", bytes: 100, in: other)
        XCTAssertTrue(DecompressedCopies.remove(in: other, keeping: []).isEmpty)
        XCTAssertTrue(exists("nsp/precious.nsp", in: other))
    }

    func testALinkInPlaceOfTheWorkOrTheNspFolderIsNeverFollowed() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try write("nsp/precious.nsp", bytes: 100, in: real)
        let workLink = root.appendingPathComponent("0100AAAA00010000_build")
        try FileManager.default.createSymbolicLink(at: workLink, withDestinationURL: real)
        XCTAssertTrue(DecompressedCopies.remove(in: workLink, keeping: []).isEmpty)

        let work = root.appendingPathComponent("0100BBBB00010000_build", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("nsp"), withDestinationURL: real.appendingPathComponent("nsp"))
        XCTAssertTrue(DecompressedCopies.remove(in: work, keeping: []).isEmpty)
        XCTAssertTrue(exists("nsp/precious.nsp", in: real))
    }

    // MARK: - The setting and what the queue says

    func testTheSettingIsOnByDefaultAndSurvivesAnOldSavedSettings() throws {
        XCTAssertTrue(LauncherSettings().removeDecompressed)
        let old = try JSONDecoder().decode(LauncherSettings.self, from: Data(#"{"keepExtracted":true,"gameFolder":"/g"}"#.utf8))
        XCTAssertTrue(old.removeDecompressed, "an older settings file has no such field: the default applies")
        var off = LauncherSettings()
        off.removeDecompressed = false
        let back = try JSONDecoder().decode(LauncherSettings.self, from: try JSONEncoder().encode(off))
        XCTAssertFalse(back.removeDecompressed)
    }

    func testAFinishedBuildSaysWhatItFreed() {
        var item = QueueItem(titleID: "01008F2005154000", name: "South Park",
                             job: .send(package: URL(fileURLWithPath: "/tmp/x"), to: "udid"))
        item.phase = .done("built v0")
        XCTAssertEqual(item.status, "built v0")
        item.note = "freed 14.1 GB (decompressed copy)"
        XCTAssertEqual(item.status, "built v0 · freed 14.1 GB (decompressed copy)")
    }
}
