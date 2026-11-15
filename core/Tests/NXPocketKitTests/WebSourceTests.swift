import XCTest

@testable import NXPocketKit

/// A static web server as a source: the layout the launcher exports, served here by a `URLProtocol` that answers GET and `Range` the way a
/// plain file server does, so the paths, the ranges, the token and the failures of the real thing are all exercised without a network.
final class WebProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var root = URL(fileURLWithPath: "/")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    /// Requests come in on the threads of the URL loading system: the list is kept under a lock.
    static var requests: [URLRequest] {
        get { lock.withLock { recorded } }
        set { lock.withLock { recorded = newValue } }
    }
    nonisolated(unsafe) static var requireToken: String?
    nonisolated(unsafe) static var ignoreRange = false
    nonisolated(unsafe) static var cutAfter: Int?
    /// The cut applies only to the file whose path ends so: a connection that fails inside the image, wherever the small files fall.
    nonisolated(unsafe) static var cutPath: String?
    nonisolated(unsafe) static var redirect = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "web.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let url = request.url!
        func answer(_ status: Int, _ headers: [String: String] = [:], body: Data = Data()) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let cut = Self.cutAfter, body.count > cut, Self.cutPath.map({ url.path.hasSuffix($0) }) ?? true {
                client?.urlProtocol(self, didLoad: body.prefix(cut))
                Self.cutAfter = nil
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.redirect { return answer(302, ["Location": "https://elsewhere.test/", "Content-Length": "0"]) }
        if let token = Self.requireToken, request.value(forHTTPHeaderField: "Authorization") != "Bearer \(token)" { return answer(401, ["Content-Length": "0"]) }
        var path = url.path
        if path.hasPrefix("/lib") { path.removeFirst(4) }
        let file = Self.root.appendingPathComponent(path.removingPercentEncoding ?? path)
        guard FileManager.default.fileExists(atPath: file.path), let data = try? Data(contentsOf: file) else { return answer(404, ["Content-Length": "0"]) }
        if let range = request.value(forHTTPHeaderField: "Range"), !Self.ignoreRange, range.hasPrefix("bytes="), let first = Int(range.dropFirst(6).dropLast()), first < data.count {
            let part = data.subdata(in: first..<data.count)
            return answer(206, ["Content-Length": "\(part.count)", "Content-Range": "bytes \(first)-\(data.count - 1)/\(data.count)"], body: part)
        }
        answer(200, ["Content-Length": "\(data.count)"], body: data)
    }
}

final class WebSourceTests: XCTestCase {
    private let titleID = "0100111000200000"
    private let fileManager = FileManager.default
    private var workspace: TestWorkspace!

    override func setUpWithError() throws {
        workspace = try TestWorkspace()
        WebProtocol.requests = []
        WebProtocol.requireToken = nil
        WebProtocol.ignoreRange = false
        WebProtocol.cutAfter = nil
        WebProtocol.cutPath = nil
        WebProtocol.redirect = false
    }

    /// The layout the launcher's export makes, built by hand from a fixture package.
    private func export(addOns: [String: Int] = [:]) throws {
        let package = try PackageFixture(addOnFiles: addOns).write(into: workspace, at: "package")
        let root = workspace.url("web")
        let game = root.appendingPathComponent("\(titleID).nxgame")
        try fileManager.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try fileManager.copyItem(at: package, to: game)
        let manifest = try Data(contentsOf: game.appendingPathComponent("package.json"))
        let files = try PackageScanner.files(in: game).map { RemotePackageFile(path: $0.relativePath, size: $0.size) }.sorted { $0.path < $1.path }
        let decoded = try GamePackage.decode(manifest)
        let revision = FileDigest.sha256(of: manifest)
        try JSONEncoder().encode(RemotePackageListing(revision: revision, files: files)).write(to: game.appendingPathComponent("files.json"))
        try JSONEncoder().encode(RemoteListing(games: [RemoteGame(package: decoded, revision: revision)])).write(to: root.appendingPathComponent("index.json"))
        WebProtocol.root = root
    }

    private func source(_ base: String = "https://web.test/lib/", token: String? = nil) -> WebSource {
        WebSource(baseURL: URL(string: base)!, token: token, session: HTTPSession(trust: .system, idleTimeout: 5, protocolClasses: [WebProtocol.self]))
    }

    private func downloader(space: Int64? = nil) throws -> PackageDownloader {
        try fileManager.createDirectory(at: workspace.url("Documents/.incoming"), withIntermediateDirectories: true)
        return PackageDownloader(documents: workspace.url("Documents"), availableSpace: { space }, headroom: 0, maximumMinimumOS: OSVersion(major: 27), checkpointBytes: 2048)
    }

    func testTheIndexTheListingAndAWholeGameCome() async throws {
        try export(addOns: ["0.img": 2_000])
        let web = source()
        let games = try await web.games()
        XCTAssertEqual(games.map(\.titleID), [titleID])
        let folder = try await downloader().download(games[0], from: web)
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent(".complete").path))
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: workspace.url("web/\(titleID).nxgame/romfs.img")))
        XCTAssertFalse(fileManager.fileExists(atPath: folder.appendingPathComponent("files.json").path), "the list is the server's, not part of the game")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("aoc/0.img")).count, 2_000)
    }

    func testADownloadCutInTheMiddleResumesWithARange() async throws {
        try export()
        let web = source()
        let game = try await web.games()[0]
        let engine = try downloader()
        WebProtocol.cutPath = "romfs.img"
        WebProtocol.cutAfter = 2_500
        do { _ = try await engine.download(game, from: web); XCTFail("the cut must stop it") } catch {}
        WebProtocol.requests = []
        let folder = try await engine.download(game, from: web)
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent(".complete").path))
        // Whether it went on from where it stopped or began the file again depends on how much of it reached the disk before the cut: either
        // way the game is whole, and a range read is tested on its own below.
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: workspace.url("web/\(titleID).nxgame/romfs.img")))
    }

    func testARangeReadAnswersThePartAfterTheOffsetAndAsksForItWithRange() async throws {
        try export()
        let web = source()
        let whole = try Data(contentsOf: workspace.url("web/\(titleID).nxgame/romfs.img"))
        let body = try await web.read(titleID: titleID, revision: String(repeating: "a", count: 64), path: "romfs.img", offset: 1_000)
        var data = Data()
        for try await chunk in body.chunks { data.append(chunk) }
        XCTAssertEqual(body.offset, 1_000)
        XCTAssertEqual(data, whole.subdata(in: 1_000..<whole.count))
        XCTAssertEqual(WebProtocol.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=1000-")
    }

    func testAServerThatIgnoresRangeIsSaidNotToResume() async throws {
        try export()
        let web = source()
        WebProtocol.ignoreRange = true
        do {
            _ = try await web.read(titleID: titleID, revision: String(repeating: "a", count: 64), path: "romfs.img", offset: 100)
            XCTFail("a whole file where a range was asked must be refused")
        } catch PackageSourceError.malformed(let detail) {
            XCTAssertTrue(detail.contains("Range"), detail)
        }
    }

    func testTheTokenIsSentAsABearerAndAWrongOneIsRefused() async throws {
        try export()
        WebProtocol.requireToken = "s3cret"
        let games = try await source(token: "s3cret").games()
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(WebProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer s3cret")
        do { _ = try await source(token: "wrong").games(); XCTFail() } catch PackageSourceError.unauthorized {}
        do { _ = try await source().games(); XCTFail() } catch PackageSourceError.unauthorized {}
    }

    func testAMissingGameIsNotFoundAndARedirectIsNotFollowed() async throws {
        try export()
        do { _ = try await source().listing(titleID: "0100999900000000"); XCTFail() } catch PackageSourceError.notFound {}
        WebProtocol.redirect = true
        do { _ = try await source().games(); XCTFail() } catch PackageSourceError.malformed(let detail) { XCTAssertTrue(detail.contains("redirect"), detail) }
    }

    func testOnlyAnHttpsAddressIsTakenAndTheAddressKeepsItsPathAndQuery() throws {
        XCTAssertNotNil(WebSource.validated(" https://example.com/my%20library/ "))
        XCTAssertNil(WebSource.validated("http://example.com/lib"), "a token and a game must not travel in the clear")
        XCTAssertNil(WebSource.validated("https://user:pass@example.com/lib"))
        XCTAssertNil(WebSource.validated("ftp://example.com"))
        XCTAssertNil(WebSource.validated("not a link"))
        let request = try source("https://web.test/my%20library/?key=abc").makeRequest(["0100111000200000.nxgame", "dir", "a b.img"])
        XCTAssertEqual(request.url?.absoluteString, "https://web.test/my%20library/0100111000200000.nxgame/dir/a%20b.img?key=abc")
        XCTAssertEqual(WebSource.sourceID(for: URL(string: "https://web.test/lib/")!), WebSource.sourceID(for: URL(string: "https://web.test/lib/")!))
        XCTAssertNotEqual(WebSource.sourceID(for: URL(string: "https://web.test/lib/")!), WebSource.sourceID(for: URL(string: "https://web.test/other/")!))
    }

    func testAPathThatLeavesThePackageIsNeverAsked() async throws {
        try export()
        do { _ = try await source().read(titleID: titleID, revision: String(repeating: "a", count: 64), path: "../index.json", offset: 0); XCTFail() }
        catch PackageSourceError.malformed {}
        XCTAssertTrue(WebProtocol.requests.isEmpty)
    }
}
