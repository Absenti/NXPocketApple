import XCTest

@testable import NXPMacKit

final class BuildFoldersTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("buildfolders-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? fileManager.removeItem(at: root) }

    private func make(_ path: String, bytes: Int = 100) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    func testOnlyAPlainTitleIDBuildFolderIsOne() throws {
        _ = try make("0100111000200000_build/x")
        _ = try make("not_a_title_build/x")
        _ = try make("0100111000200000_builds/x")
        _ = try make("01001110002000_build/x")
        XCTAssertTrue(BuildFolders.isBuildFolder(root.appendingPathComponent("0100111000200000_build")))
        for other in ["not_a_title_build", "0100111000200000_builds", "01001110002000_build", "missing_build"] {
            XCTAssertFalse(BuildFolders.isBuildFolder(root.appendingPathComponent(other)), other)
        }
        XCTAssertEqual(BuildFolders.titleID(of: root.appendingPathComponent("0100f08026d0c000_build")), nil, "it must exist to be one")
    }

    func testRemovingOneTakesItsFilesButNotWhatItsLinksPointAt() throws {
        let dump = try make("dumps/Game [0100111000200000].nsp", bytes: 5000)
        let folder = root.appendingPathComponent("0100111000200000_build")
        _ = try make("0100111000200000_build/extract/big.bin", bytes: 2000)
        try fileManager.createDirectory(at: folder.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: folder.appendingPathComponent("inputs/Game.nsp"), withDestinationURL: dump)
        let freed = try XCTUnwrap(BuildFolders.remove(folder))
        XCTAssertGreaterThanOrEqual(freed, 2000)
        XCTAssertLessThan(freed, 2000 + 5000, "the dump a link points at is not counted")
        XCTAssertFalse(fileManager.fileExists(atPath: folder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: dump.path), "a link is removed as a link: the dump is untouched")
    }

    func testAFolderThatIsNotOneIsNeverRemovedAndALinkInItsPlaceIsLeftAlone() throws {
        let other = try make("games/keepme")
        XCTAssertNil(BuildFolders.remove(root.appendingPathComponent("games")))
        XCTAssertTrue(fileManager.fileExists(atPath: other.path))
        let target = root.appendingPathComponent("precious")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        _ = try make("precious/file")
        let link = root.appendingPathComponent("0100111000200000_build")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(BuildFolders.remove(link), "a link standing where the folder goes is not deleted through")
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("precious/file").path))
    }

    func testFindsTheFoldersInTheRootAndInItsFoldersButNoDeeper() throws {
        _ = try make("0100111000200000_build/a")
        _ = try make("south_park/010043600B6A6000_build/a")
        _ = try make("south_park/deeper/0100AAAA00000000_build/a")
        _ = try make("0100222000300000_notbuild/a")
        let found = BuildFolders.find(in: [root, root]).map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        XCTAssertEqual(found.sorted(), ["0100111000200000_build", "south_park/010043600B6A6000_build"])
    }
}
