import XCTest
@testable import NXPMacKit
@testable import NXPocketKit

/// A phone sends a copy of a game's saves: the real server, the real client, TLS on the loopback. Everything the Mac must
/// refuse is refused from the head of the request, and what it keeps is exactly the file that was sent, in the one place it
/// may write.
final class SaveUploadTests: XCTestCase {
    private var workspace: URL!
    private var output: URL!
    private var keys: URL!
    private var devices: PairedDevices!
    private var server: ShareServer!
    private var port: UInt16 = 0
    private var accepting = true
    private let titleID = ShareFixture.titleID

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-saves-\(UUID().uuidString)", isDirectory: true)
        output = workspace.appendingPathComponent("output", isDirectory: true)
        keys = workspace.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let built = workspace.appendingPathComponent("built", isDirectory: true)
        try ShareFixture.build(in: built, scratch: workspace)
        devices = PairedDevices(folder: keys)
        let outputFolder = output!
        let inbox = SaveInbox(outputFolder: { outputFolder }, accepting: { [unowned self] in self.accepting })
        server = ShareServer(identity: try ServerIdentity.load(from: keys), library: SharedLibrary(folder: built, cacheLife: 30),
                             devices: devices, name: "Test Mac", saves: inbox)
        port = try await server.start(port: 0, advertise: false)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: workspace)
    }

    private var lastToken = ""

    private func source() async throws -> PinnedHTTPSSource {
        let offer = try XCTUnwrap(server.beginPairing())
        let mac = try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: offer.code, deviceName: "Test iPhone")
        lastToken = mac.token
        return PinnedHTTPSSource(mac)
    }

    private func archive(bytes: Int = 4_000, name: String = "copy.zip") throws -> URL {
        let url = workspace.appendingPathComponent(name)
        try (SaveUpload.zipMagic + Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })).write(to: url)
        return url
    }

    private var gameFolder: URL { SaveBackup.folder(of: titleID, in: output) }

    private func kept() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: gameFolder.path)) ?? []).sorted()
    }

    func testACopyIsKeptByteForByteUnderTheGamesFolder() async throws {
        let phone = try await source()
        let file = try archive()
        try await phone.store(saves: file, titleID: titleID)
        let names = kept()
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(SaveUpload.isCopyName(try XCTUnwrap(names.first)), names.joined())
        XCTAssertEqual(try Data(contentsOf: gameFolder.appendingPathComponent(names[0])), try Data(contentsOf: file))
        XCTAssertEqual(SaveBackup.backups(of: titleID, in: output), [], "a zip is not a cable backup, and does not disturb them")
    }

    func testOnlyTheLastTenCopiesAreKeptAndOnlyOnesItNamed() async throws {
        let phone = try await source()
        try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: gameFolder.appendingPathComponent("iPhone old notes.zip"))
        for index in 0..<(SaveUpload.keep + 2) {
            let name = "iPhone 2020-01-\(String(format: "%02d", index + 1)) 100000.zip"
            try (SaveUpload.zipMagic + Data("x".utf8)).write(to: gameFolder.appendingPathComponent(name))
        }
        try await phone.store(saves: try archive(), titleID: titleID)
        let names = kept()
        XCTAssertEqual(names.filter(SaveUpload.isCopyName).count, SaveUpload.keep)
        XCTAssertTrue(names.contains("iPhone old notes.zip"), "a file the player put there is not counted and not removed")
        XCTAssertFalse(names.contains("iPhone 2020-01-01 100000.zip"), "the oldest went")
    }

    func testAPhoneThatIsNotPairedWritesNothing() async throws {
        let phone = try await source()
        let stranger = PinnedHTTPSSource(host: "127.0.0.1", port: Int(port), pin: phone.pin, token: String(repeating: "a", count: 64))
        do { try await stranger.store(saves: try archive(), titleID: titleID); XCTFail("must be refused") }
        catch PackageSourceError.unauthorized {}
        XCTAssertEqual(kept(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: SaveBackup.root(in: output).path))
    }

    func testARevokedPhoneWritesNothing() async throws {
        let phone = try await source()
        server.revoke(deviceID: try XCTUnwrap(devices.all.first).id)
        do { try await phone.store(saves: try archive(), titleID: titleID); XCTFail("must be refused") }
        catch PackageSourceError.unauthorized {}
        XCTAssertEqual(kept(), [])
    }

    func testTheSwitchOffRefusesAndSaysSo() async throws {
        let phone = try await source()
        accepting = false
        do { try await phone.store(saves: try archive(), titleID: titleID); XCTFail("must be refused") }
        catch PackageSourceError.notAccepting {}
        XCTAssertEqual(kept(), [])
    }

    func testAFileThatIsNotAZipIsNotKept() async throws {
        let phone = try await source()
        // The phone's own check comes first, so this goes around it: the Mac must not rely on it.
        let url = URL(string: "https://127.0.0.1:\(port)/v1/saves/\(titleID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(lastToken)", forHTTPHeaderField: "Authorization")
        let session = HTTPSession(trust: .pinned(phone.pin))
        defer { session.invalidate() }
        let junk = workspace.appendingPathComponent("junk.bin")
        try Data("not a zip at all".utf8).write(to: junk)
        let transfer = session.upload(request, file: junk)
        let response = try await transfer.awaitHead()
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(kept().filter { !$0.hasPrefix(".") }, [])
        XCTAssertEqual(kept(), [], "the partial file is removed too")
    }

    func testOnlyAGamesTitleIDNamesAFolder() async throws {
        let phone = try await source()
        let session = HTTPSession(trust: .pinned(phone.pin))
        defer { session.invalidate() }
        let file = try archive()
        for bad in ["..", "0100111000200000%2F..", "0100000000000801", "not-a-title"] {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/saves/\(bad)")!)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(lastToken)", forHTTPHeaderField: "Authorization")
            let response = try await session.upload(request, file: file).awaitHead()
            XCTAssertTrue([400, 404, 405].contains(response.statusCode), "\(bad) answered \(response.statusCode)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: SaveBackup.root(in: output).path))
    }

    func testAPutAnywhereElseIsRefused() async throws {
        let phone = try await source()
        let session = HTTPSession(trust: .pinned(phone.pin))
        defer { session.invalidate() }
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/games/\(titleID)/files/x")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(lastToken)", forHTTPHeaderField: "Authorization")
        let response = try await session.upload(request, file: try archive()).awaitHead()
        XCTAssertEqual(response.statusCode, 405)
    }

    func testTheLimitOnTheSizeIsAnnouncedByTheHeadAndEnforced() throws {
        func head(_ length: String) -> Data {
            Data("PUT /v1/saves/\(titleID) HTTP/1.1\r\nHost: x\r\nContent-Length: \(length)\r\n\r\n".utf8)
        }
        if case .failure(let status) = HTTPParser.parse(head("\(SaveUpload.maxBytes + 1)")) { XCTAssertEqual(status, 413) } else { XCTFail() }
        if case .failure(let status) = HTTPParser.parse(head("0")) { XCTAssertEqual(status, 411) } else { XCTFail() }
        if case .failure(let status) = HTTPParser.parse(head("-5")) { XCTAssertEqual(status, 411) } else { XCTFail() }
        if case .upload(_, let length, _) = HTTPParser.parse(head("1000")) { XCTAssertEqual(length, 1000) } else { XCTFail() }
        let chunked = Data("PUT /v1/saves/\(titleID) HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        if case .failure(let status) = HTTPParser.parse(chunked) { XCTAssertEqual(status, 400) } else { XCTFail() }
    }

    func testNoRoomIsAnswered507BeforeABodyIsRead() throws {
        let inbox = SaveInbox(outputFolder: { self.output }, room: { _ in 1_000 })
        XCTAssertThrowsError(try inbox.begin(titleID: titleID, length: 5_000)) { XCTAssertEqual($0 as? SaveInbox.Refusal, .noRoom) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: SaveBackup.root(in: output).path), "refused before anything was made")
    }

    func testACopyCutShortLeavesNothing() throws {
        let inbox = SaveInbox(outputFolder: { self.output })
        let upload = try inbox.begin(titleID: titleID, length: 100)
        try upload.write(SaveUpload.zipMagic + Data(repeating: 1, count: 10))
        XCTAssertThrowsError(try upload.commit()) { XCTAssertEqual($0 as? SaveInbox.Refusal, .cut) }
        XCTAssertEqual(kept(), [])
    }

    func testAMoreLongBodyThanAnnouncedIsRefused() throws {
        let inbox = SaveInbox(outputFolder: { self.output })
        let upload = try inbox.begin(titleID: titleID, length: 10)
        XCTAssertThrowsError(try upload.write(SaveUpload.zipMagic + Data(repeating: 1, count: 20))) {
            XCTAssertEqual($0 as? SaveInbox.Refusal, .tooLarge)
        }
        XCTAssertEqual(kept(), [])
    }


    // MARK: giving copies back

    func testTheCopiesAPhoneSentComeBackNewestFirstAndByteForByte() async throws {
        let phone = try await source()
        let first = try archive(bytes: 1_000, name: "first.zip")
        let second = try archive(bytes: 2_000, name: "second.zip")
        let namedFirst = try await phone.store(saves: first, titleID: titleID)
        try await Task.sleep(nanoseconds: 1_100_000_000)   // a copy is named by the second
        let namedSecond = try await phone.store(saves: second, titleID: titleID)
        XCTAssertTrue(SaveUpload.isCopyName(namedFirst), "the Mac says the name it gave: how a phone knows its own copies")

        let copies = try await phone.saveCopies(titleID: titleID)
        XCTAssertEqual(copies.map(\.name), [namedSecond, namedFirst])
        XCTAssertEqual(copies.first?.size, Int64(try Data(contentsOf: second).count))

        let back = workspace.appendingPathComponent("back.zip")
        try await phone.fetchSaveCopy(titleID: titleID, name: namedSecond, to: back)
        XCTAssertEqual(try Data(contentsOf: back), try Data(contentsOf: second))
    }

    func testAFileThePlayerPutThereIsNeitherListedNorServed() async throws {
        let phone = try await source()
        try await phone.store(saves: try archive(), titleID: titleID)
        try Data("mine".utf8).write(to: gameFolder.appendingPathComponent("iPhone notes.zip"))
        try Data("secret".utf8).write(to: gameFolder.appendingPathComponent("backup.json"))
        let names = try await phone.saveCopies(titleID: titleID).map(\.name)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names.contains("iPhone notes.zip"))
        let back = workspace.appendingPathComponent("x.zip")
        do { try await phone.fetchSaveCopy(titleID: titleID, name: "iPhone notes.zip", to: back); XCTFail() } catch is NXPocketError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: back.path))
    }

    func testCopiesAreNotGivenToAStrangerOrWhenTheSwitchIsOff() async throws {
        let phone = try await source()
        let stored = try await phone.store(saves: try archive(), titleID: titleID)
        let stranger = PinnedHTTPSSource(host: "127.0.0.1", port: Int(port), pin: phone.pin, token: String(repeating: "c", count: 64))
        do { _ = try await stranger.saveCopies(titleID: titleID); XCTFail() } catch PackageSourceError.unauthorized {}
        accepting = false
        do { _ = try await phone.saveCopies(titleID: titleID); XCTFail() } catch PackageSourceError.notAccepting {}
        do { try await phone.fetchSaveCopy(titleID: titleID, name: stored, to: workspace.appendingPathComponent("y.zip")); XCTFail() }
        catch PackageSourceError.notAccepting {}
    }

    func testAGameWithNoCopyHasAnEmptyList() async throws {
        let list = try await source().saveCopies(titleID: titleID)
        XCTAssertTrue(list.isEmpty)
    }
}
