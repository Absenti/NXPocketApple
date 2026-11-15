import NXPocketKit
import XCTest

@testable import NXShellHost

final class TransferWatchTests: XCTestCase {
    private var documents: URL!

    override func setUpWithError() throws {
        documents = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: documents.appendingPathComponent(".incoming"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: documents) }

    /// A transfer as the Mac leaves it partway: `package.json` first, then a piece of `romfs.img`.
    @discardableResult
    private func transfer(romfsBytes: Int, marker: String? = nil) throws -> URL {
        let folder = documents.appendingPathComponent(".incoming/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package: [String: Any] = ["schema": 1, "title_id": "0100111000200000", "name": "Fixture", "version": "1.0.0",
                                      "package_version": "65536", "framework": "DmGame0100111000200000.framework",
                                      "chain": "b-3f9a2c", "min_os": "26.0", "romfs_id": "", "romfs_size": 4000,
                                      "aoc_size": 0, "files": [], "created_by": "tests"]
        try JSONSerialization.data(withJSONObject: package).write(to: folder.appendingPathComponent("package.json"))
        try Data(count: romfsBytes).write(to: folder.appendingPathComponent("romfs.img"))
        if let marker { try Data("x\n".utf8).write(to: folder.appendingPathComponent(marker)) }
        return folder
    }

    func testAGameOnItsWayIsNamedAndMeasuredAgainstItsPackage() throws {
        try transfer(romfsBytes: 1000)
        let incoming = IncomingTransfers.receiving(documents: documents)
        XCTAssertEqual(incoming.count, 1)
        XCTAssertEqual(incoming.first?.title, "Fixture")
        XCTAssertEqual(incoming.first?.expected, 4000)
        XCTAssertGreaterThanOrEqual(incoming.first?.received ?? 0, 1000)
        XCTAssertEqual(incoming.first?.fraction ?? 0, Double(incoming.first!.received) / 4000, accuracy: 0.000_1)
    }

    func testATransferBeforeItsPackageArrivesHasNoFractionYet() throws {
        let folder = documents.appendingPathComponent(".incoming/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("DmGame.framework"), withIntermediateDirectories: true)
        let incoming = IncomingTransfers.receiving(documents: documents)
        XCTAssertNil(incoming.first?.title)
        XCTAssertNil(incoming.first?.fraction)
    }

    func testAFinishedOrAbandonedTransferIsNotOnItsWay() throws {
        try transfer(romfsBytes: 10, marker: GameLayout.completeMarker)
        try transfer(romfsBytes: 10, marker: GameLayout.abandonedMarker)
        XCTAssertTrue(IncomingTransfers.receiving(documents: documents).isEmpty)
    }

    @MainActor
    func testATransferThatStopsGrowingIsCalledStoppedAndCanBeDeleted() throws {
        let saved = ShellHostModel.stalledAfter
        ShellHostModel.stalledAfter = 0
        defer { ShellHostModel.stalledAfter = saved }
        let model = ShellHostModel(documents: documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        let folder = try transfer(romfsBytes: 100)
        model.checkTransfers()
        XCTAssertEqual(model.receiving.count, 1)
        model.checkTransfers()
        XCTAssertTrue(model.receiving.first?.stalled == true, "the same byte count twice, with no time allowed")
        // More bytes arrive: it is on its way again.
        try Data(count: 500).write(to: folder.appendingPathComponent("romfs.img"))
        ShellHostModel.stalledAfter = 3600
        model.checkTransfers()
        XCTAssertTrue(model.receiving.first?.stalled == false)
        model.discardTransfer(folder.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(model.receiving.isEmpty)
    }

    @MainActor
    func testATransferTheMacCancelledIsRemovedWhileTheAppIsOpen() throws {
        let model = ShellHostModel(documents: documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        let folder = try transfer(romfsBytes: 100)
        model.checkTransfers()
        XCTAssertEqual(model.receiving.count, 1)
        try Data("x\n".utf8).write(to: folder.appendingPathComponent(GameLayout.abandonedMarker))
        model.checkTransfers()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the Mac's cancel does not wait for the next start")
        XCTAssertTrue(model.receiving.isEmpty)
    }

    @MainActor
    func testATransferThatLandsWhileTheAppIsOpenShowsWithoutARelaunch() throws {
        let model = ShellHostModel(documents: documents, engineHost: UnlinkedEngineHost(), signer: UnavailableSigner())
        guard model.signingIdentity == nil else { throw XCTSkip("a certificate is installed in this keychain") }
        XCTAssertEqual(model.pendingTransfers, 0)
        let folder = try transfer(romfsBytes: 100)
        model.checkTransfers()
        XCTAssertEqual(model.receiving.map(\.folder.lastPathComponent), [folder.lastPathComponent])
        try Data("complete\n".utf8).write(to: folder.appendingPathComponent(GameLayout.completeMarker))
        model.checkTransfers()
        XCTAssertTrue(model.receiving.isEmpty)
        XCTAssertEqual(model.pendingTransfers, 1, "seen at the next look, not at the next start of the app")
        XCTAssertEqual(model.importState, .idle, "without a certificate nothing can be signed, so nothing starts")
    }
}
