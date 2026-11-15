import NXPocketKit
import XCTest

@testable import NXPocketSFTP

/// The SFTP client against a real OpenSSH server (`SSHDHarness`): browsing, downloading, resuming, and every way a server
/// or a key can be wrong.
final class SFTPSourceTests: XCTestCase {
    private var workspace: URL!
    private var sshd: SSHDHarness!
    private var builds: URL!
    private let titleID = "0100111000200000"

    override func setUpWithError() throws {
        // /tmp, not the temporary directory: unix sockets and ssh's own paths like short ones.
        workspace = URL(fileURLWithPath: "/private/tmp/nxsftp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        sshd = try SSHDHarness.start(in: workspace.appendingPathComponent("sshd"))
        builds = workspace.appendingPathComponent("server/builds", isDirectory: true)
        try Self.makeGame(in: builds, titleID: titleID)
        try Data("not a game".utf8).write(to: builds.appendingPathComponent("readme.txt"))
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("server/other"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sshd?.stop()
        try? FileManager.default.removeItem(at: workspace)
    }

    private func config(hostKey: String? = nil, folder: String? = nil, port: Int? = nil, user: String? = nil) -> SFTPConfig {
        SFTPConfig(host: "127.0.0.1", port: port ?? sshd.port, user: user ?? sshd.user, hostKey: hostKey ?? sshd.hostKeyPin,
                   folder: folder ?? builds.path)
    }

    private func source(_ config: SFTPConfig? = nil, key: String? = nil) -> SFTPSource {
        SFTPSource(config: config ?? self.config(), credential: SFTPCredential(privateKey: key ?? sshd.clientKey), idleTimeout: 8)
    }

    private func downloader() -> PackageDownloader {
        PackageDownloader(documents: workspace.appendingPathComponent("Documents"), availableSpace: { nil }, headroom: 0,
                          maximumMinimumOS: OSVersion(major: 99), checkpointBytes: 100_000)
    }

    /// A package as the Mac writes one, minus the code a verifier would look into: a framework with a few files, a RomFS image
    /// of several slots, an add-on file.
    @discardableResult
    static func makeGame(in folder: URL, titleID: String, romfsBytes: Int = 400_000) throws -> URL {
        let root = folder.appendingPathComponent("\(titleID).nxgame", isDirectory: true)
        let framework = "DmGame\(titleID).framework"
        let inside = root.appendingPathComponent(framework, isDirectory: true)
        try FileManager.default.createDirectory(at: inside.appendingPathComponent("dm"), withIntermediateDirectories: true)
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
        let contents: [(String, Data)] = [("DmGame", random(9_000)), ("game.manifest.json", random(300)), ("dm/profile.tsv", random(40))]
        var entries: [GamePackage.FileEntry] = []
        for (name, data) in contents {
            try data.write(to: inside.appendingPathComponent(name))
            entries.append(GamePackage.FileEntry(path: name, size: Int64(data.count), sha256: FileDigest.sha256(of: data)))
        }
        try random(romfsBytes).write(to: root.appendingPathComponent("romfs.img"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aoc"), withIntermediateDirectories: true)
        try random(5_000).write(to: root.appendingPathComponent("aoc/0.img"))
        let package = GamePackage(titleID: TitleID(titleID)!, name: "SFTP Game", version: "1.0", packageVersion: "1", framework: framework,
                                  chain: "b-3f9a2c", minOS: "26.0", romfsID: "", romfsSize: Int64(romfsBytes), aocSize: 5_000,
                                  files: entries.sorted { $0.path < $1.path }, createdBy: "tests")
        try package.data().write(to: root.appendingPathComponent("package.json"))
        return root
    }

    // MARK: copies of saves

    private func savesZip(_ bytes: Int = 300_000) throws -> URL {
        let url = workspace.appendingPathComponent("saves-\(UUID().uuidString.prefix(6)).zip")
        try (SaveUpload.zipMagic + Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })).write(to: url)
        return url
    }

    /// A PNG that passes `PNGHeader`: the signature and an IHDR of 64 by 64 pixels, as much of one as that check reads.
    private static func smallPNG() -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8)
        data += Data([0, 0, 0, 64, 0, 0, 0, 64, 8, 6, 0, 0, 0]) + Data(count: 20)
        return data
    }

    func testTheGamesIconComesFromTheFrameworkOnTheServer() async throws {
        let icon = builds.appendingPathComponent("\(titleID).nxgame/DmGame\(titleID).framework/icon.png")
        try Self.smallPNG().write(to: icon)
        let found = try await source().icon(titleID: titleID)
        XCTAssertEqual(found, Self.smallPNG())
    }

    func testNoIconOrOneThatIsNotAPNGIsNilAndNotAnError() async throws {
        let icon = builds.appendingPathComponent("\(titleID).nxgame/DmGame\(titleID).framework/icon.png")
        let none = try await source().icon(titleID: titleID)
        XCTAssertNil(none, "a package with no icon")
        try Data("not an image at all, only text that is long enough to be read".utf8).write(to: icon)
        let text = try await source().icon(titleID: titleID)
        XCTAssertNil(text)
        try Data(repeating: 0x89, count: SharingLimits.iconBytes + 1).write(to: icon)
        let large = try await source().icon(titleID: titleID)
        XCTAssertNil(large, "an icon beyond the bound is not read whole")
    }

    // MARK: a built game put on the server

    /// A package as the Mac keeps it, in a folder of its own on this machine.
    private func localPackage(romfsBytes: Int = 400_000) throws -> URL {
        let folder = workspace.appendingPathComponent("local-\(UUID().uuidString.prefix(6))", isDirectory: true)
        return try Self.makeGame(in: folder, titleID: titleID, romfsBytes: romfsBytes)
    }

    private func sameTree(_ one: URL, _ two: URL) throws -> Bool {
        let first = try SFTPSource.uploadPlan(package: one).files
        let second = try SFTPSource.uploadPlan(package: two).files
        guard first == second else { return false }
        for file in first where try Data(contentsOf: one.appendingPathComponent(file.path)) != Data(contentsOf: two.appendingPathComponent(file.path)) { return false }
        return true
    }

    func testAGameIsPutOnTheServerWholeAndTheListThenHasIt() async throws {
        let package = try localPackage()
        let target = builds.appendingPathComponent("new/deeper", isDirectory: true)
        let server = source(config(folder: target.path))
        let seen = Seen()
        try await server.upload(package: package) { seen.add($0) }
        XCTAssertTrue(try sameTree(package, target.appendingPathComponent("\(titleID).nxgame")))
        XCTAssertEqual(seen.last, 1, "the progress ends at the whole")
        XCTAssertTrue(seen.isRising)
        let games = try await server.games()
        XCTAssertEqual(games.map(\.titleID), [titleID])
        // The phone's own download of it, from the server, is what the Mac put there.
        let downloaded = try await downloader().download(games[0], from: server)
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: downloaded.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: package.appendingPathComponent("romfs.img")))
    }

    func testAGameAlreadyThereIsReplacedByTheNewBuild() async throws {
        let target = builds.appendingPathComponent("replace", isDirectory: true)
        let server = source(config(folder: target.path))
        try await server.upload(package: try localPackage(romfsBytes: 100_000))
        let second = try localPackage(romfsBytes: 120_000)
        try await server.upload(package: second)
        XCTAssertTrue(try sameTree(second, target.appendingPathComponent("\(titleID).nxgame")), "nothing of the earlier build is kept")
    }

    func testAnUploadThatIsStoppedLeavesNoGameForThePhoneToTake() async throws {
        let package = try localPackage(romfsBytes: 2_000_000)
        let target = builds.appendingPathComponent("stopped", isDirectory: true)
        let server = source(config(folder: target.path))
        // Stopped as soon as the first bytes are on the server: the image and `package.json` have not been sent.
        let handle = TaskBox()
        let task = Task { try await server.upload(package: package) { _ in handle.cancel() } }
        handle.task = task
        do {
            try await task.value
            XCTFail("it must be stopped")
        } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .cancelled)
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("\(titleID).nxgame/package.json").path),
                       "package.json is what lists a game: a game that is not whole is not offered")
        let games = try await server.games()
        XCTAssertTrue(games.isEmpty)
    }

    func testOnlyABuiltGameWithoutLinksIsSent() throws {
        let other = workspace.appendingPathComponent("not-a-game", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SFTPSource.uploadPlan(package: other))
        let package = try localPackage()
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("aoc/link"), withDestinationURL: workspace)
        XCTAssertThrowsError(try SFTPSource.uploadPlan(package: package)) { XCTAssertEqual(($0 as? NXPocketError)?.code, .symbolicLink) }
        try FileManager.default.removeItem(at: package.appendingPathComponent("aoc/link"))
        try FileManager.default.removeItem(at: package.appendingPathComponent("package.json"))
        XCTAssertThrowsError(try SFTPSource.uploadPlan(package: package)) { XCTAssertEqual(($0 as? NXPocketError)?.code, .packageMissing) }
    }

    func testTheOrderMakesTheGameAppearLast() throws {
        let package = try localPackage()
        try Data("x".utf8).write(to: package.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: package.appendingPathComponent(".complete"))
        let files = try SFTPSource.uploadPlan(package: package).files.map(\.path)
        XCTAssertEqual(files.suffix(2), ["romfs.img", "package.json"], files.joined(separator: ","))
        XCTAssertFalse(files.contains(".DS_Store") || files.contains(".complete"))
    }

    func testACopyOfSavesIsKeptInAHiddenFolderBesideTheGames() async throws {
        let file = try savesZip()
        let server = source()
        try await server.store(saves: file, titleID: titleID)
        let folder = builds.appendingPathComponent("\(SaveUpload.sftpFolder)/\(titleID)")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.count, 1, names.joined(separator: ","))
        XCTAssertTrue(SaveUpload.isCopyName(names[0]))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(names[0])), try Data(contentsOf: file))
        let games = try await server.games()
        XCTAssertEqual(games.map(\.titleID), [titleID], "the copies are not games, and do not disturb the list")
        try await server.store(saves: file, titleID: titleID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2, "a second copy in the same second is a second file")
    }

    func testOnlyTheLastTenCopiesStayOnTheServer() async throws {
        let folder = builds.appendingPathComponent("\(SaveUpload.sftpFolder)/\(titleID)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for day in 1...11 {
            try SaveUpload.zipMagic.write(to: folder.appendingPathComponent("iPhone 2020-02-\(String(format: "%02d", day)) 080000.zip"))
        }
        try Data("keep me".utf8).write(to: folder.appendingPathComponent("my notes.txt"))
        try await source().store(saves: try savesZip(2_000), titleID: titleID)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.filter(SaveUpload.isCopyName).count, SaveUpload.keep)
        XCTAssertTrue(names.contains("my notes.txt"))
        XCTAssertFalse(names.contains("iPhone 2020-02-01 080000.zip"))
        XCTAssertFalse(names.contains { $0.hasPrefix(".part-") }, "no temporary file is left")
    }

    func testAFileThatIsNotAZipOrNotAGameIsNotSent() async throws {
        let junk = workspace.appendingPathComponent("junk.zip")
        try Data("nope".utf8).write(to: junk)
        do { try await source().store(saves: junk, titleID: titleID); XCTFail("must not be sent") } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .packageDamaged)
        }
        do { try await source().store(saves: try savesZip(100), titleID: "../etc"); XCTFail("must not be sent") } catch let error as NXPocketError {
            XCTAssertEqual(error.code, .packageDamaged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: builds.appendingPathComponent(SaveUpload.sftpFolder).path))
    }

    func testTheCopiesOnTheServerAreListedNewestFirstAndComeBackWhole() async throws {
        let server = source()
        let first = try savesZip(5_000)
        let second = try savesZip(9_000)
        let namedFirst = try await server.store(saves: first, titleID: titleID)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let namedSecond = try await server.store(saves: second, titleID: titleID)
        XCTAssertTrue(SaveUpload.isCopyName(namedFirst))

        let copies = try await server.saveCopies(titleID: titleID)
        XCTAssertEqual(copies.map(\.name), [namedSecond, namedFirst])
        let back = workspace.appendingPathComponent("back.zip")
        try await server.fetchSaveCopy(titleID: titleID, name: namedSecond, to: back)
        XCTAssertEqual(try Data(contentsOf: back), try Data(contentsOf: second))
    }

    func testAGameWithNoCopiesHasAnEmptyListAndAForeignNameIsNotFetched() async throws {
        let server = source()
        let none = try await server.saveCopies(titleID: titleID)
        XCTAssertTrue(none.isEmpty)
        let back = workspace.appendingPathComponent("never.zip")
        do { try await server.fetchSaveCopy(titleID: titleID, name: "../../etc/passwd", to: back); XCTFail() } catch is NXPocketError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: back.path))
    }

    // MARK: the key of the server

    func testShowsTheServersKeyBeforeAnythingSecretIsSent() async throws {
        let key = try await SFTPSource.hostKey(of: SFTPConfig(host: "127.0.0.1", port: sshd.port, user: sshd.user))
        XCTAssertEqual(key.pin, sshd.hostKeyPin)
        XCTAssertEqual(key.type, "ssh-ed25519")
        XCTAssertTrue(key.display.hasPrefix("SHA256:"))
        XCTAssertFalse(key.display.contains("="), "as ssh prints it, unpadded")
    }

    func testAnotherKeyThanTheAcceptedOneStopsTheConnection() async throws {
        let wrong = source(config(hostKey: String(repeating: "0", count: 64)))
        do { _ = try await wrong.directories(in: "/"); XCTFail("a server whose key changed must be refused") }
        catch PackageSourceError.untrusted(let fingerprint) { XCTAssertEqual(fingerprint, sshd.hostKeyPin) }
    }

    func testNothingIsSentWithoutAKeyThePlayerAccepted() async throws {
        let unpinned = SFTPSource(config: SFTPConfig(host: "127.0.0.1", port: sshd.port, user: sshd.user, folder: builds.path),
                                  credential: SFTPCredential(password: "hunter2"))
        do { _ = try await unpinned.games(); XCTFail("a server not yet trusted is not connected to") }
        catch PackageSourceError.untrusted {}
    }

    // MARK: browsing and downloading

    func testBrowsesTheServerAndListsTheGamesInThePickedFolder() async throws {
        let top = source(config(folder: workspace.appendingPathComponent("server").path))
        let home = try await top.homeDirectory()
        XCTAssertFalse(home.isEmpty)
        let folders = try await top.directories(in: workspace.appendingPathComponent("server").path)
        XCTAssertEqual(folders, ["builds", "other"], "folders only, sorted")
        let inside = try await top.directories(in: builds.path)
        XCTAssertEqual(inside, ["\(titleID).nxgame"])

        let games = try await source().games()

        XCTAssertEqual(games.map(\.titleID), [titleID])
        XCTAssertEqual(games.first?.name, "SFTP Game")
        XCTAssertTrue(FileDigest.isSHA256(games.first?.revision ?? ""))
    }

    func testDownloadsAWholeGameWithPipelinedReads() async throws {
        let sftp = source()
        let first = try await sftp.games().first
        let game = try XCTUnwrap(first)

        let folder = try await downloader().download(game, from: sftp)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path))
        let served = builds.appendingPathComponent("\(titleID).nxgame")
        for path in ["romfs.img", "aoc/0.img", "DmGame\(titleID).framework/DmGame"] {
            XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent(path)),
                           try FileDigest.sha256(ofFileAt: served.appendingPathComponent(path)), path)
        }
        XCTAssertEqual(try PackageVerifier.loadPackage(folder).name, "SFTP Game")
    }

    func testAReadFromAnOffsetReturnsTheRest() async throws {
        let sftp = source()
        let listing = try await sftp.listing(titleID: titleID)
        let all = try Data(contentsOf: builds.appendingPathComponent("\(titleID).nxgame/romfs.img"))

        let body = try await sftp.read(titleID: titleID, revision: listing.revision, path: "romfs.img", offset: 150_001)
        var received = Data()
        for try await chunk in body.chunks { received.append(chunk) }

        XCTAssertEqual(body.offset, 150_001)
        XCTAssertEqual(body.length, UInt64(all.count - 150_001))
        XCTAssertEqual(received, all.subdata(in: 150_001..<all.count), "slots are handed out in order, whatever their sizes")
        let end = try await sftp.read(titleID: titleID, revision: listing.revision, path: "romfs.img", offset: UInt64(all.count))
        var nothing = Data()
        for try await chunk in end.chunks { nothing.append(chunk) }
        XCTAssertTrue(nothing.isEmpty)
    }

    func testAnOffsetPastTheEndOfTheFileIsRefused() async throws {
        let sftp = source()
        let listing = try await sftp.listing(titleID: titleID)
        do { _ = try await sftp.read(titleID: titleID, revision: listing.revision, path: "romfs.img", offset: 10_000_000); XCTFail("past the end") }
        catch PackageSourceError.malformed {}
    }

    func testAStreamThatIsDroppedCloses() async throws {
        let sftp = source()
        let listing = try await sftp.listing(titleID: titleID)
        for _ in 0..<5 {
            let body = try await sftp.read(titleID: titleID, revision: listing.revision, path: "romfs.img", offset: 0)
            var iterator = body.chunks.makeAsyncIterator()
            _ = try await iterator.next()   // one slot read, the rest abandoned
        }
        let games = try await sftp.games()
        XCTAssertEqual(games.count, 1, "the connection still works after five abandoned reads")
    }

    // MARK: who is asking

    func testAKeyTheServerDoesNotKnowIsRefused() async throws {
        let stranger = source(key: try sshd.strangerKey())
        do { _ = try await stranger.games(); XCTFail("an unauthorised key must be refused") }
        catch PackageSourceError.unauthorized {}
    }

    func testAnUnknownUserIsRefused() async throws {
        let nobody = source(config(user: "no-such-user-here"))
        do { _ = try await nobody.games(); XCTFail("an unknown user must be refused") }
        catch PackageSourceError.unauthorized {}
    }

    func testAPrivateKeyThatCannotBeReadIsSaidSo() async throws {
        let garbage = source(key: "-----BEGIN OPENSSH PRIVATE KEY-----\nnot a key\n-----END OPENSSH PRIVATE KEY-----")
        do { _ = try await garbage.games(); XCTFail("garbage is not a key") }
        catch PackageSourceError.malformed(let reason) { XCTAssertTrue(reason.contains("ed25519"), reason) }
    }

    func testNothingListensOnAClosedPort() async throws {
        let none = source(config(port: 1))
        do { _ = try await none.games(); XCTFail("nothing answers on port 1") }
        catch PackageSourceError.unreachable {}
    }

    // MARK: a server that is not honest about a package

    func testALinkInAPackageIsRefused() async throws {
        let root = builds.appendingPathComponent("\(titleID).nxgame")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sneaky"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let sftp = source()
        _ = try await sftp.games()
        do { _ = try await sftp.listing(titleID: titleID); XCTFail("a link is no part of a package") }
        catch PackageSourceError.malformed(let reason) { XCTAssertTrue(reason.contains("link"), reason) }
    }

    func testALinkAsThePackageFolderIsNotAGame() async throws {
        try FileManager.default.createSymbolicLink(at: builds.appendingPathComponent("0100222000300000.nxgame"),
                                                   withDestinationURL: builds.appendingPathComponent("\(titleID).nxgame"))
        let games = try await source().games()
        XCTAssertEqual(games.map(\.titleID), [titleID])
    }

    func testAnOddNameIsRefused() async throws {
        let root = builds.appendingPathComponent("\(titleID).nxgame")
        try Data("x".utf8).write(to: root.appendingPathComponent("a\nb"))
        let sftp = source()
        _ = try await sftp.games()
        do { _ = try await sftp.listing(titleID: titleID); XCTFail("a name with a line break is refused") }
        catch PackageSourceError.malformed {}
    }

    func testAPathThatLeavesThePackageIsNeverAsked() async throws {
        let sftp = source()
        let listing = try await sftp.listing(titleID: titleID)
        for bad in ["../readme.txt", "/etc/passwd", "a/../../b", "..", ""] {
            do { _ = try await sftp.read(titleID: titleID, revision: listing.revision, path: bad, offset: 0); XCTFail(bad) }
            catch PackageSourceError.malformed {}
        }
    }

    func testAGameThatIsNotThereIsNotFound() async throws {
        do { _ = try await source().listing(titleID: "0100AAAA00000000"); XCTFail("no such game") }
        catch PackageSourceError.notFound {}
    }

    func testAFolderThatIsNotThereIsNotFound() async throws {
        let missing = source(config(folder: builds.appendingPathComponent("absent").path))
        do { _ = try await missing.games(); XCTFail("no such folder") }
        catch PackageSourceError.notFound {}
    }

    func testATamperedFileIsRefusedByItsHash() async throws {
        let sftp = source()
        let first = try await sftp.games().first
        let game = try XCTUnwrap(first)
        let file = builds.appendingPathComponent("\(titleID).nxgame/DmGame\(titleID).framework/DmGame")
        var bytes = try Data(contentsOf: file)
        bytes[0] ^= 0xFF
        try bytes.write(to: file)

        do { _ = try await downloader().download(game, from: sftp); XCTFail("a changed file must be refused") }
        catch let error as NXPocketError { XCTAssertEqual(error.code, .hashMismatch) }
    }
}

final class SFTPConfigTests: XCTestCase {
    func testACredentialIsOneStringThatComesBack() {
        let password = SFTPCredential(password: "p@ss\"word")
        XCTAssertEqual(SFTPCredential.decode(password.secret), password)
        let key = SFTPCredential(privateKey: "-----BEGIN-----\nabc\n", passphrase: "x")
        XCTAssertEqual(SFTPCredential.decode(key.secret), key)
        XCTAssertNil(SFTPCredential.decode("plain text"))
        XCTAssertNil(SFTPCredential.decode("{}"), "a credential with nothing in it is not one")
    }

    func testTheFingerprintIsShownAsOpenSSHShowsIt() {
        // sha256("") base64, unpadded: 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU
        let empty = SFTPHostKey(pin: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", type: "ssh-ed25519")
        XCTAssertEqual(empty.display, "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    func testTwoFoldersOfOneServerAreTwoSources() {
        let one = SFTPConfig(host: "box", user: "me", folder: "/a")
        var two = one
        two.folder = "/b"
        XCTAssertNotEqual(SFTPSource.sourceID(for: one), SFTPSource.sourceID(for: two))
        XCTAssertEqual(SFTPSource.sourceID(for: one), SFTPSource.sourceID(for: one))
    }
}


/// What an upload reported, from the threads it reports on.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double? { lock.withLock { values.last } }
    var isRising: Bool { lock.withLock { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } && values.count > 1 } }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Error>?
    var task: Task<Void, Error>? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
    func cancel() { task?.cancel() }
}
