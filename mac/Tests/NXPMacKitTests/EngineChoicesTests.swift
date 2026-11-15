import XCTest

@testable import NXPMacKit

final class EngineChoicesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("engines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// An engine tree: the files that make it usable, and the stamp `engine.py sync` leaves (or none).
    @discardableResult
    private func engine(_ name: String, stamp: String?) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: url.appendingPathComponent("dm/tools"), withIntermediateDirectories: true)
        try Data("#".utf8).write(to: url.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        try Data("#".utf8).write(to: url.appendingPathComponent("dm/tools/romfs_image.py"))
        if let stamp {
            try fileManager.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try Data(stamp.utf8).write(to: url.appendingPathComponent(".git/nx2apple-stamp"))
        }
        return url
    }

    func testTheStableReleaseIsToldByItsKeyAndListedFirst() throws {
        let mine = try engine("mine", stamp: "nx2apple-engine 1\npin 81906931262fb25d774cce8bca2db8926439e5a2\nkey \(String(repeating: "d", count: 64))\n")
        let stable = try engine("stable", stamp: "nx2apple-engine 1\npin ccd834e06a3938834bb5579e2ccc6a0ad13d3970\nkey \(SetupPins.engineKey)\n")
        let choices = EngineChoices.available(selected: nil, candidates: [mine, stable], pinnedInstall: root.appendingPathComponent("none"))
        XCTAssertEqual(choices.map(\.url.lastPathComponent), ["stable", "mine"])
        XCTAssertTrue(choices[0].isStable)
        XCTAssertEqual(choices[0].title, "NX2Apple \(SetupPins.nx2appleVersion), stable")
        XCTAssertFalse(choices[1].isStable)
        XCTAssertTrue(choices[1].detail.contains("81906931"), choices[1].detail)
    }

    func testATreeWithoutAStampIsSaidToBeOfUnknownVersionAndAFolderThatIsNoEngineIsNotListed() throws {
        let plain = try engine("plain", stamp: nil)
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let choices = EngineChoices.available(selected: empty, candidates: [plain], pinnedInstall: root.appendingPathComponent("none"))
        XCTAssertEqual(choices.map(\.url.lastPathComponent), ["plain"])
        XCTAssertFalse(choices[0].isStable)
        XCTAssertTrue(choices[0].detail.contains("not known"))
    }

    func testTheSameEngineReachedTwoWaysIsListedOnce() throws {
        let one = try engine("one", stamp: nil)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: one)
        XCTAssertEqual(EngineChoices.available(selected: link, candidates: [one], pinnedInstall: root.appendingPathComponent("none")).count, 1)
    }

    func testTheLauncherInstallIsMarkedAsSuch() throws {
        let installed = try engine("install", stamp: "nx2apple-engine 1\npin ccd834e06a3938834bb5579e2ccc6a0ad13d3970\nkey \(SetupPins.engineKey)\n")
        let choices = EngineChoices.available(selected: nil, candidates: [], pinnedInstall: installed)
        XCTAssertTrue(choices[0].detail.contains("installed by this launcher"), choices[0].detail)
    }
}
