import XCTest

@testable import NXPMacKit
@testable import NXPocketKit

/// A static file server for one folder, as a plain web server answers GET and Range.
private final class FolderServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var root = URL(fileURLWithPath: "/")
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "library.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        func answer(_ status: Int, _ headers: [String: String], _ body: Data = Data()) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        let file = Self.root.appendingPathComponent(url.path.removingPercentEncoding ?? url.path)
        guard let data = try? Data(contentsOf: file) else { return answer(404, ["Content-Length": "0"]) }
        if let range = request.value(forHTTPHeaderField: "Range"), let first = Int(range.dropFirst(6).dropLast()), first < data.count {
            let part = data.subdata(in: first..<data.count)
            return answer(206, ["Content-Length": "\(part.count)", "Content-Range": "bytes \(first)-\(data.count - 1)/\(data.count)"], part)
        }
        answer(200, ["Content-Length": "\(data.count)"], data)
    }
}

/// The launcher exports the built games for a web server, and the iPhone's source reads what was exported, end to end.
final class WebExportTests: XCTestCase {
    private var workspace: URL!
    private var built: URL!
    private var out: URL!
    private let titleID = ShareFixture.titleID

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-web-\(UUID().uuidString)", isDirectory: true)
        built = workspace.appendingPathComponent("built", isDirectory: true)
        out = workspace.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try ShareFixture.build(in: built, scratch: workspace)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: workspace) }

    func testTheExportHoldsTheIndexTheGameWithItsListAndNothingTheSharingServerWouldNotServe() throws {
        try Data("secret".utf8).write(to: built.appendingPathComponent("prod.keys"))
        try Data("x".utf8).write(to: built.appendingPathComponent("\(titleID).nxgame/.signing.json"))
        let report = try WebExport.export(from: built, to: out)
        XCTAssertEqual(report.games, 1)

        let games = try RemoteListing.decode(Data(contentsOf: out.appendingPathComponent("index.json")))
        XCTAssertEqual(games.map(\.titleID), [titleID])
        let listing = try RemotePackageListing.decode(Data(contentsOf: out.appendingPathComponent("\(titleID).nxgame/files.json")))
        XCTAssertEqual(listing.revision, games[0].revision)
        let paths = listing.files.map(\.path)
        XCTAssertTrue(paths.contains("package.json") && paths.contains("romfs.img") && paths.contains("romfs.blocks"))
        XCTAssertFalse(paths.contains("files.json"), "the list does not list itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("\(titleID).nxgame/.signing.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("prod.keys").path))
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: out.path)).filter { $0.hasPrefix(".export-") }
        XCTAssertTrue(leftovers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("icons/\(titleID).png").path), "the icon is a PNG the phone accepts")
    }

    func testTheIPhoneDownloadsAndVerifiesWhatWasExported() async throws {
        _ = try WebExport.export(from: built, to: out)
        FolderServer.root = out
        let web = WebSource(baseURL: URL(string: "https://library.test/")!, token: nil,
                            session: HTTPSession(trust: .system, idleTimeout: 5, protocolClasses: [FolderServer.self]))
        let games = try await web.games()
        let icon = try await web.icon(titleID: titleID)
        XCTAssertNotNil(icon)
        let documents = workspace.appendingPathComponent("Phone", isDirectory: true)
        let downloader = PackageDownloader(documents: documents, availableSpace: { nil }, headroom: 0, maximumMinimumOS: OSVersion(major: 99))
        let folder = try await downloader.download(games[0], from: web)
        XCTAssertNoThrow(try PackageVerifier.verify(folder, options: VerifyOptions(maximumMinimumOS: OSVersion(major: 99))))
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: built.appendingPathComponent("\(titleID).nxgame/romfs.img")))
    }

    func testAnotherExportReplacesTheGameAndAnEmptyLibraryIsRefused() throws {
        _ = try WebExport.export(from: built, to: out)
        try Data("stale".utf8).write(to: out.appendingPathComponent("\(titleID).nxgame/old-file"))
        _ = try WebExport.export(from: built, to: out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("\(titleID).nxgame/old-file").path), "the game's folder is replaced whole")

        let empty = workspace.appendingPathComponent("nothing", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try WebExport.export(from: empty, to: workspace.appendingPathComponent("out2"))) {
            XCTAssertEqual(($0 as? NXPocketError)?.code, .packageMissing)
        }
    }
}
