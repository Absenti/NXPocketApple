import XCTest

@testable import NXPMacKit
@testable import NXPocketKit

/// An iPhone asks the Mac to build a game of the player's dump folder: the real server and client over TLS on the loopback, with a
/// stand-in for the launcher's queue.
final class BuildRequestTests: XCTestCase {
    private final class Port: BuildPort, @unchecked Sendable {
        var allowsBuilds = true
        var games: [RemoteBuildable] = []
        var asked: [String] = []
        var answer: BuildAnswer = .accepted
        func buildable() -> [RemoteBuildable] { games }
        func requestBuild(titleID: String) -> BuildAnswer {
            asked.append(titleID)
            return answer
        }
    }

    private var workspace: URL!
    private var server: ShareServer!
    private var port: UInt16 = 0
    private let port0 = Port()
    private let built = ShareFixture.titleID
    private let unbuilt = "0100111000300000"

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-builds-\(UUID().uuidString)", isDirectory: true)
        let folder = workspace.appendingPathComponent("built", isDirectory: true)
        let keys = workspace.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try ShareFixture.build(in: folder, scratch: workspace)
        port0.games = [RemoteBuildable(titleID: unbuilt, name: "Not Built Yet", state: .idle),
                       RemoteBuildable(titleID: built, name: "Shared Game", state: .idle)]
        server = ShareServer(identity: try ServerIdentity.load(from: keys), library: SharedLibrary(folder: folder, cacheLife: 30),
                             devices: PairedDevices(folder: keys), name: "Test Mac", builds: port0)
        port = try await server.start(port: 0, advertise: false)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: workspace)
    }

    private func phone() async throws -> PinnedHTTPSSource {
        let offer = try XCTUnwrap(server.beginPairing())
        return PinnedHTTPSSource(try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: offer.code, deviceName: "Test iPhone"))
    }

    func testTheListOffersTheGamesThatAreNotBuiltYet() async throws {
        let list = try await phone().buildable()
        XCTAssertEqual(list.map(\.titleID), [unbuilt], "a game already built is not offered to be built")
        XCTAssertEqual(list.first?.state, .idle)
    }

    func testNothingIsOfferedWhileThePlayerHasNotAllowedIt() async throws {
        port0.allowsBuilds = false
        let source = try await phone()
        let listing = try await source.buildableListing()
        XCTAssertTrue(listing.games.isEmpty)
        XCTAssertFalse(listing.allowed, "the phone is told why the list is empty, and nothing about the games")
        do { try await source.requestBuild(titleID: unbuilt); XCTFail("must be refused") } catch PackageSourceError.notAccepting {}
        XCTAssertTrue(port0.asked.isEmpty)
    }

    func testAnAcceptedRequestReachesTheLauncherWithOnlyATitleID() async throws {
        try await phone().requestBuild(titleID: unbuilt.lowercased())
        XCTAssertEqual(port0.asked, [unbuilt])
    }

    func testAGameAlreadyBuiltOrUnknownOrNotAGameIsNotQueued() async throws {
        let source = try await phone()
        do { try await source.requestBuild(titleID: built); XCTFail() } catch PackageSourceError.notFound {}
        port0.answer = .notFound
        do { try await source.requestBuild(titleID: "0100999900000000"); XCTFail() } catch PackageSourceError.notFound {}
        do { try await source.requestBuild(titleID: "../x"); XCTFail() } catch is NXPocketError {}
        XCTAssertEqual(port0.asked, ["0100999900000000"], "only a game that is not built reaches the launcher")
    }

    func testABusyLauncherSaysSo() async throws {
        port0.answer = .busy
        do { try await phone().requestBuild(titleID: unbuilt); XCTFail() } catch PackageSourceError.busy {}
    }

    func testAPhoneThatIsNotPairedCannotAsk() async throws {
        let paired = try await phone()
        let stranger = PinnedHTTPSSource(host: "127.0.0.1", port: Int(port), pin: paired.pin, token: String(repeating: "b", count: 64))
        do { try await stranger.requestBuild(titleID: unbuilt); XCTFail() } catch PackageSourceError.unauthorized {}
        do { _ = try await stranger.buildable(); XCTFail() } catch PackageSourceError.unauthorized {}
        XCTAssertTrue(port0.asked.isEmpty)
    }

    func testTheBoardRefusesAGameAlreadyQueuedAndTooManyAtOnce() {
        let board = BuildBoard()
        var asked: [String] = []
        board.ask = { asked.append($0) }
        let ids = ["0100111000300000", "0100111000400000", "0100111000500000", "0100111000600000"]
        board.set(ids.map { RemoteBuildable(titleID: $0, name: $0, state: .idle) }, allowed: true)
        XCTAssertEqual(board.requestBuild(titleID: ids[0]), BuildAnswer.accepted)
        XCTAssertEqual(board.requestBuild(titleID: ids[0]), BuildAnswer.busy, "already queued")
        XCTAssertEqual(board.requestBuild(titleID: ids[1]), BuildAnswer.accepted)
        XCTAssertEqual(board.requestBuild(titleID: ids[2]), BuildAnswer.accepted)
        XCTAssertEqual(board.requestBuild(titleID: ids[3]), BuildAnswer.busy, "three at once is the most")
        XCTAssertEqual(asked, Array(ids.prefix(3)))
        board.set([], allowed: false)
        XCTAssertEqual(board.requestBuild(titleID: ids[3]), BuildAnswer.notFound)
    }
}
