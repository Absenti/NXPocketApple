import XCTest

@testable import NXPocketKit

/// A package folder that can also be read as segments: each segment's request names the file on disk, and `FakeTransport` serves it.
private final class SegmentFolder: BackgroundReadable, @unchecked Sendable {
    let inner: FolderSource
    init(_ inner: FolderSource) { self.inner = inner }
    var sourceID: String { inner.sourceID }
    func games() async throws -> [RemoteGame] { try await inner.games() }
    func listing(titleID: String) async throws -> RemotePackageListing { try await inner.listing(titleID: titleID) }
    func icon(titleID: String) async throws -> Data? { nil }
    func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody {
        try await inner.read(titleID: titleID, revision: revision, path: path, offset: offset)
    }
    func segmentBase(titleID: String, revision: String, path: String) throws -> (request: URLRequest, trust: SegmentTrust) {
        (URLRequest(url: inner.root.appendingPathComponent(path)), .system)
    }
}

/// What the system's service does, without a system: a segment is the right bytes of the file its request names, on demand.
private final class FakeTransport: SegmentTransport, @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var asked: [String: SegmentRequest] = [:]
    private(set) var order: [String] = []
    private(set) var cancelled: [String] = []
    private(set) var widest = 0
    /// Keys whose segment comes out the wrong length, or refused.
    var shortKeys = Set<String>()
    var refusedKeys = Set<String>()
    private var read = 0

    init(folder: URL) { self.folder = folder }

    func enqueue(_ segment: SegmentRequest) async throws {
        lock.withLock {
            guard asked[segment.key] == nil else { return }
            asked[segment.key] = segment
            order.append(segment.key)
            widest = max(widest, order.count - read)
        }
    }

    func completion(of key: String) async throws -> URL {
        let segment = try lock.withLock { () -> SegmentRequest in
            guard let segment = asked[key] else { throw PackageSourceError.unreachable("not asked for") }
            read += 1
            return segment
        }
        if refusedKeys.contains(key) { throw PackageSourceError.notFound }
        let handle = try FileHandle(forReadingFrom: segment.request.url!)
        defer { try? handle.close() }
        try handle.seek(toOffset: segment.first)
        var data = try handle.read(upToCount: Int(segment.length)) ?? Data()
        if shortKeys.contains(key) { data = data.dropLast() }
        let out = folder.appendingPathComponent(UUID().uuidString)
        try data.write(to: out)
        return out
    }

    func cancel(keys: [String]) async { lock.withLock { cancelled.append(contentsOf: keys) } }
}

final class SegmentedSourceTests: XCTestCase {
    private func make(_ workspace: TestWorkspace, segment: UInt64 = 700, window: Int = 3) throws
        -> (source: SegmentedSource, folder: FolderSource, transport: FakeTransport) {
        let folder = try workspace.makeSource(PackageFixture(addOnFiles: ["0.img": 3000, "1.img": 1500]))
        let transport = FakeTransport(folder: workspace.url("segments"))
        try FileManager.default.createDirectory(at: transport.folder, withIntermediateDirectories: true)
        return (SegmentedSource(inner: SegmentFolder(folder), transport: transport, segmentBytes: segment, window: window, smallestFile: 100),
                folder, transport)
    }

    private func bytes(_ body: RemoteBody) async throws -> Data {
        var data = Data()
        for try await chunk in body.chunks { data.append(chunk) }
        return data
    }

    private func revision(_ source: SegmentedSource) async throws -> String { try await source.listing(titleID: "0100111000200000").revision }

    func testABigFileComesOutWholeFromItsSegments() async throws {
        let workspace = try TestWorkspace()
        let (source, folder, transport) = try make(workspace)
        let revision = try await revision(source)
        let body = try await source.read(titleID: "0100111000200000", revision: revision, path: "aoc/0.img", offset: 0)
        let data = try await bytes(body)
        XCTAssertEqual(data, try Data(contentsOf: folder.root.appendingPathComponent("aoc/0.img")))
        XCTAssertEqual(body.length, 3000)
        XCTAssertEqual(transport.order.count, 5, "3000 bytes in segments of 700")
        XCTAssertTrue(folder.reads.isEmpty, "the ordinary read is not used for a file that is cut into segments")
    }

    func testTheSegmentsAskedForAheadNeverPassTheWindow() async throws {
        let workspace = try TestWorkspace()
        let (source, _, transport) = try make(workspace, window: 2)
        let revision = try await revision(source)
        _ = try await bytes(try await source.read(titleID: "0100111000200000", revision: revision, path: "aoc/0.img", offset: 0))
        XCTAssertLessThanOrEqual(transport.widest, 2)
        XCTAssertGreaterThanOrEqual(transport.widest, 2, "the service always has work queued")
    }

    func testAResumeInTheMiddleOfASegmentSkipsWhatIsAlreadyOnDisk() async throws {
        let workspace = try TestWorkspace()
        let (source, folder, transport) = try make(workspace)
        let revision = try await revision(source)
        let body = try await source.read(titleID: "0100111000200000", revision: revision, path: "aoc/0.img", offset: 1234)
        XCTAssertEqual(body.offset, 1234)
        XCTAssertEqual(body.length, 3000 - 1234)
        let data = try await bytes(body)
        XCTAssertEqual(data, try Data(contentsOf: folder.root.appendingPathComponent("aoc/0.img")).dropFirst(1234))
        XCTAssertFalse(transport.order.contains { $0.hasSuffix("-0") }, "the segments before the offset are not asked for")
    }

    func testADroppedReadStopsWhatItAskedForAndHasNotRead() async throws {
        let workspace = try TestWorkspace()
        let (source, _, transport) = try make(workspace, window: 4)
        let revision = try await revision(source)
        do {
            let body = try await source.read(titleID: "0100111000200000", revision: revision, path: "aoc/0.img", offset: 0)
            var iterator = body.chunks.makeAsyncIterator()
            _ = try await iterator.next()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.cancelled.count, 4, "all four asked for, none finished reading, are stopped")
    }

    func testASmallFileIsReadTheOrdinaryWay() async throws {
        let workspace = try TestWorkspace()
        let folder = try workspace.makeSource(PackageFixture(addOnFiles: ["0.img": 3000]))
        let transport = FakeTransport(folder: workspace.url("segments"))
        let source = SegmentedSource(inner: SegmentFolder(folder), transport: transport, segmentBytes: 700, window: 3, smallestFile: 1 << 20)
        let revision = try await revision(source)
        _ = try await bytes(try await source.read(titleID: "0100111000200000", revision: revision, path: "aoc/0.img", offset: 0))
        XCTAssertTrue(transport.order.isEmpty)
        XCTAssertEqual(folder.reads.count, 1)
    }

    func testASegmentOfTheWrongLengthIsRefused() async throws {
        let workspace = try TestWorkspace()
        let (source, _, transport) = try make(workspace)
        let revision = try await revision(source)
        transport.shortKeys = [transport.keyOfSegment(1, source: source, revision: revision, path: "aoc/0.img")]
        do {
            _ = try await bytes(try await source.read(titleID: "0100111000200000", revision: revision, path: "aoc/0.img", offset: 0))
            XCTFail("a short part must not be taken for the file")
        } catch PackageSourceError.malformed {}
    }

    func testARebuiltPackageIsReportedAsChanged() async throws {
        let workspace = try TestWorkspace()
        let (source, _, _) = try make(workspace)
        do {
            _ = try await source.read(titleID: "0100111000200000", revision: String(repeating: "f", count: 64), path: "aoc/0.img", offset: 0)
            XCTFail("the plan is not the source's any more")
        } catch PackageSourceError.changed {}
    }

    func testAWholeDownloadThroughSegmentsIsTheSamePackageAsAnOrdinaryOne() async throws {
        let workspace = try TestWorkspace()
        let (source, folder, _) = try make(workspace)
        let downloader = try workspace.makeDownloader()
        let result = try await downloader.download(.fixture(), from: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent(GameLayout.completeMarker).path))
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: result.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: folder.root.appendingPathComponent("romfs.img")))
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: result.appendingPathComponent("aoc/0.img")),
                       try FileDigest.sha256(ofFileAt: folder.root.appendingPathComponent("aoc/0.img")))
    }

    func testAKeyIsAFileNameAndStaysTheSameForTheSameFile() {
        let a = SegmentedSource.keyPrefix(sourceID: "mac-abc123", titleID: "0100111000200000", revision: String(repeating: "a", count: 64), path: "data/romfs.img")
        let b = SegmentedSource.keyPrefix(sourceID: "mac-abc123", titleID: "0100111000200000", revision: String(repeating: "a", count: 64), path: "data/romfs.img")
        let other = SegmentedSource.keyPrefix(sourceID: "mac-abc123", titleID: "0100111000200000", revision: String(repeating: "a", count: 64), path: "data/other.img")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, other)
        XCTAssertFalse(a.contains("/"))
        XCTAssertTrue(a.contains("-0100111000200000-"), "a game's segments can be found and removed by its title ID")
        XCTAssertFalse(SegmentedSource.keyPrefix(sourceID: "web-../x", titleID: "0100111000200000", revision: "r", path: "p").contains("/"))
    }
}

private extension FakeTransport {
    func keyOfSegment(_ index: Int, source: SegmentedSource, revision: String, path: String) -> String {
        "\(SegmentedSource.keyPrefix(sourceID: source.sourceID, titleID: "0100111000200000", revision: revision, path: path))-\(index)"
    }
}

final class BackgroundTransfersTests: XCTestCase {
    private let info = BackgroundTransfers.Info(key: "k", first: 700, length: 700, total: 3000)

    private func response(_ status: Int, range: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://h/x")!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: range.map { ["Content-Range": $0] } ?? [:])!
    }

    func testOnlyTheExactRangeThatWasAskedForIsAccepted() {
        XCTAssertNil(BackgroundTransfers.problem(response: response(206, range: "bytes 700-1399/3000"), size: 700, for: info))
        XCTAssertNotNil(BackgroundTransfers.problem(response: response(206, range: "bytes 0-699/3000"), size: 700, for: info), "another range")
        XCTAssertNotNil(BackgroundTransfers.problem(response: response(206, range: "bytes 700-1399/9999"), size: 700, for: info), "another file's length")
        XCTAssertNotNil(BackgroundTransfers.problem(response: response(206), size: 700, for: info), "no Content-Range")
        XCTAssertNotNil(BackgroundTransfers.problem(response: response(206, range: "bytes 700-1399/3000"), size: 699, for: info), "a body that is short")
        XCTAssertNotNil(BackgroundTransfers.problem(response: nil, size: 700, for: info))
    }

    func testAServerThatIgnoresRangeIsOnlyAcceptedWhenTheSegmentIsTheWholeFile() {
        XCTAssertNotNil(BackgroundTransfers.problem(response: response(200), size: 700, for: info), "the whole file sent for a part")
        let whole = BackgroundTransfers.Info(key: "k", first: 0, length: 500, total: 500)
        XCTAssertNil(BackgroundTransfers.problem(response: response(200), size: 500, for: whole))
    }

    func testTheServersRefusalsKeepTheirMeaning() {
        func code(_ status: Int) -> PackageSourceError? { BackgroundTransfers.problem(response: response(status), size: 0, for: info) as? PackageSourceError }
        XCTAssertEqual(code(401), .unauthorized)
        XCTAssertEqual(code(404), .notFound)
        XCTAssertEqual(code(409), .changed)
        XCTAssertEqual(code(423), .busy)
    }

    func testHowAServerIsTrustedSurvivesInAFileAndNothingElseDoes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pin = String(repeating: "ab", count: 32)
        let text = #"{"192.168.1.5:4433":"pin:\#(pin)","web.example:443":"system","x:1":"pin:short","y:2":"anything"}"#
        try Data(text.utf8).write(to: folder.appendingPathComponent("trust.json"))
        let table = BackgroundTransfers.loadTrust(from: folder)
        XCTAssertEqual(table["192.168.1.5:4433"], .pinned(pin))
        XCTAssertEqual(table["web.example:443"], .system)
        XCTAssertNil(table["x:1"], "a pin that is not a key hash")
        XCTAssertNil(table["y:2"])
        XCTAssertEqual(SegmentTrust(token: SegmentTrust.pinned(pin).token), .pinned(pin))
    }

    func testThereIsNoBackgroundServiceOutsideAnApp() {
        XCTAssertNil(BackgroundTransfers.shared, "a test run is not an app")
    }
}
