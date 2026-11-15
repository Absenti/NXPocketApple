import XCTest
import NXPocketKit

@testable import NXPMacKit

/// The real server, the real client and the real downloader, over TLS on the loopback: what a phone and a Mac do, minus
/// the radio. A key, a token, a code and a path are all given their wrong value here, and the answer is looked at.
final class ShareServerTests: XCTestCase {
    private var workspace: URL!
    private var built: URL!
    private var keys: URL!
    private var identity: ServerIdentity!
    private var devices: PairedDevices!
    private var library: SharedLibrary!
    private var server: ShareServer!
    private var port: UInt16 = 0
    private let titleID = ShareFixture.titleID

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-share-\(UUID().uuidString)", isDirectory: true)
        built = workspace.appendingPathComponent("built", isDirectory: true)
        keys = workspace.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try ShareFixture.build(in: built, scratch: workspace)
        identity = try ServerIdentity.load(from: keys)
        devices = PairedDevices(folder: keys)
        library = SharedLibrary(folder: built, cacheLife: 30)
        server = ShareServer(identity: identity, library: library, devices: devices, name: "Test Mac")
        port = try await server.start(port: 0, advertise: false)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: workspace)
    }

    private func pair(name: String = "Test iPhone") async throws -> PairedMac {
        let offer = try XCTUnwrap(server.beginPairing())
        return try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: offer.code, deviceName: name)
    }

    private func expectFailure<E: Error & Equatable>(_ expected: E, _ body: () async throws -> Void,
                                                     file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch let error as E { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("expected \(expected), got \(error)", file: file, line: line) }
    }

    // MARK: pairing and the pin

    func testHelloShowsTheKeyAPhoneWillPin() async throws {
        let hello = try await PinnedHTTPSSource.hello(host: "127.0.0.1", port: Int(port))
        XCTAssertEqual(hello.pin, identity.pin)
        XCTAssertEqual(hello.name, "Test Mac")
    }

    func testPairsListsAndDownloadsAGame() async throws {
        let mac = try await pair()
        XCTAssertEqual(mac.pin, identity.pin)
        XCTAssertEqual(mac.token.count, 64)
        XCTAssertEqual(devices.all.map(\.name), ["Test iPhone"])
        XCTAssertFalse(try String(contentsOf: keys.appendingPathComponent(PairedDevices.fileName), encoding: .utf8).contains(mac.token),
                       "the Mac keeps the token's hash, never the token")

        let source = PinnedHTTPSSource(mac)
        let games = try await source.games()
        XCTAssertEqual(games.map(\.titleID), [titleID])
        XCTAssertEqual(games[0].name, "Shared Game")
        XCTAssertFalse(games[0].busy)
        let icon = try await source.icon(titleID: titleID)
        XCTAssertNotNil(icon)

        let documents = workspace.appendingPathComponent("Documents", isDirectory: true)
        let downloader = PackageDownloader(documents: documents, availableSpace: { nil }, headroom: 0, maximumMinimumOS: OSVersion(major: 99))
        let folder = try await downloader.download(games[0], from: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(GameLayout.completeMarker).path))
        let verified = try PackageVerifier.verify(folder, options: VerifyOptions(maximumMinimumOS: OSVersion(major: 99)))
        XCTAssertEqual(verified.titleID.description, titleID)
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")),
                       try FileDigest.sha256(ofFileAt: built.appendingPathComponent("\(titleID).nxgame/romfs.img")))
    }

    func testAnUpdateStartsFromTheImageThePhoneHoldsAndEndsWithTheMacsImage() async throws {
        let source = PinnedHTTPSSource(try await pair())
        let game = try await source.games()[0]
        let macImage = built.appendingPathComponent("\(titleID).nxgame/romfs.img")
        // The phone holds an older image: the Mac's, with a change in its middle.
        var older = try Data(contentsOf: macImage)
        older[older.count / 2] ^= 0xFF
        let held = workspace.appendingPathComponent("held-romfs.img")
        try older.write(to: held)

        let documents = workspace.appendingPathComponent("UpdateDocuments", isDirectory: true)
        let downloader = PackageDownloader(documents: documents, availableSpace: { nil }, headroom: 0,
                                           maximumMinimumOS: OSVersion(major: 99), reference: { _ in held })
        let folder = try await downloader.download(game, from: source)

        XCTAssertEqual(try FileDigest.sha256(ofFileAt: folder.appendingPathComponent("romfs.img")), try FileDigest.sha256(ofFileAt: macImage))
        XCTAssertEqual(try Data(contentsOf: held), older, "the image the phone held is left as it was")
        XCTAssertNoThrow(try PackageVerifier.verify(folder, options: VerifyOptions(maximumMinimumOS: OSVersion(major: 99))))
    }

    func testAnotherKeyIsRefused() async throws {
        let mac = try await pair()
        let wrong = PinnedHTTPSSource(host: "127.0.0.1", port: Int(port), pin: String(repeating: "0", count: 64), token: mac.token)
        do { _ = try await wrong.games(); XCTFail("a key that is not the pinned one must be refused") }
        catch PackageSourceError.untrusted(let fingerprint) { XCTAssertEqual(fingerprint, identity.pin, "the fingerprint it saw is reported") }
    }

    func testNoTokenAndAWrongTokenAreTheSameRefusal() async throws {
        _ = try await pair()
        for token in ["", String(repeating: "a", count: 64), "short"] {
            let source = PinnedHTTPSSource(host: "127.0.0.1", port: Int(port), pin: identity.pin, token: token)
            await expectFailure(PackageSourceError.unauthorized) { _ = try await source.games() }
        }
    }

    func testAWrongCodeIsRefusedAndTheCodeIsBurntAfterThreeTries() async throws {
        let offer = try XCTUnwrap(server.beginPairing())
        let wrong = offer.code == "000-000" ? "111-111" : "000-000"
        for _ in 0..<3 {
            await expectFailure(PairingError.refused) {
                _ = try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: wrong, deviceName: "Phone")
            }
        }
        await expectFailure(PairingError.refused) {
            _ = try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: offer.code, deviceName: "Phone")
        }
        XCTAssertTrue(devices.all.isEmpty)
        XCTAssertNil(server.pairing.current, "three wrong proofs close the pairing")
    }

    func testACodeWorksOnce() async throws {
        let offer = try XCTUnwrap(server.beginPairing())
        _ = try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: offer.code, deviceName: "First")
        await expectFailure(PairingError.refused) {
            _ = try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: offer.code, deviceName: "Second")
        }
        XCTAssertEqual(devices.all.map(\.name), ["First"])
    }

    func testNoPairingWhenNoCodeIsShowing() async throws {
        await expectFailure(PairingError.refused) {
            _ = try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: "123-456", deviceName: "Phone")
        }
    }

    func testATypedCodeThatIsNotACodeNeverLeavesThePhone() async throws {
        await expectFailure(PairingError.malformedCode) {
            _ = try await PinnedHTTPSSource.pair(host: "127.0.0.1", port: Int(port), code: "123", deviceName: "Phone")
        }
    }

    // MARK: the QR code and the number

    private func link(secret: String? = nil, pin: String? = nil) throws -> PairLink {
        let offer = try XCTUnwrap(server.beginPairing())
        return PairLink(address: "127.0.0.1", port: Int(port), pin: pin ?? identity.pin, secret: secret ?? offer.secret, name: "Test Mac")
    }

    func testAScannedLinkPairs() async throws {
        let mac = try await PinnedHTTPSSource.pair(link: try link(), deviceName: "Scanner")
        XCTAssertEqual(mac.pin, identity.pin)
        XCTAssertEqual(devices.all.map(\.name), ["Scanner"])
        XCTAssertNil(server.pairing.current)
        _ = try await PinnedHTTPSSource(mac).games()
    }

    func testALinkNamingAnotherKeyIsNotTrustedAndSendsNothing() async throws {
        // The QR code says a different key than the one this server presents: whoever answers is not the Mac that showed it.
        let wrong = try link(pin: String(repeating: "0", count: 64))
        await expectFailure(PairingError.wrongMac) { _ = try await PinnedHTTPSSource.pair(link: wrong, deviceName: "Scanner") }
        XCTAssertTrue(devices.all.isEmpty)
        XCTAssertNotNil(server.pairing.current, "and the real window was not spent on it")
    }

    func testALinkWithAnotherSecretIsRefused() async throws {
        let wrong = try link(secret: PairingProof.makeSecret())
        await expectFailure(PairingError.refused) { _ = try await PinnedHTTPSSource.pair(link: wrong, deviceName: "Scanner") }
        XCTAssertTrue(devices.all.isEmpty)
    }

    func testComparingANumberPairsOnceBothSidesAgree() async throws {
        _ = try XCTUnwrap(server.beginPairing())
        let comparison = try await NumberPairing.begin(host: "127.0.0.1", port: Int(port), deviceName: "Comparer")
        let shown = try XCTUnwrap(server.pairing.request)
        XCTAssertEqual(shown.name, "Comparer")
        XCTAssertEqual(shown.number, comparison.number, "both screens show the same six digits")
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            server.pairing.approve()
        }
        let mac = try await comparison.confirm(timeout: 10, interval: 0.1)
        XCTAssertEqual(mac.pin, identity.pin)
        XCTAssertEqual(devices.all.map(\.name), ["Comparer"])
        _ = try await PinnedHTTPSSource(mac).games()
    }

    func testARefusedNumberIsNotPaired() async throws {
        _ = try XCTUnwrap(server.beginPairing())
        let comparison = try await NumberPairing.begin(host: "127.0.0.1", port: Int(port), deviceName: "Comparer")
        server.pairing.deny()
        await expectFailure(PairingError.refused) { _ = try await comparison.confirm(timeout: 10, interval: 0.1) }
        XCTAssertTrue(devices.all.isEmpty)
    }

    func testAnExplicitDifferenceCancelsTheRequest() async throws {
        _ = try XCTUnwrap(server.beginPairing())
        let comparison = try await NumberPairing.begin(host: "127.0.0.1", port: Int(port), deviceName: "Comparer")
        await comparison.cancel()
        XCTAssertNil(server.pairing.request)
        await expectFailure(PairingError.refused) { _ = try await comparison.confirm(timeout: 2, interval: 0.1) }
    }

    func testNoNumberToCompareWithoutAWindow() async throws {
        await expectFailure(PairingError.refused) {
            _ = try await NumberPairing.begin(host: "127.0.0.1", port: Int(port), deviceName: "Comparer")
        }
    }

    // MARK: revocation

    func testARevokedPhoneIsRefusedAtOnce() async throws {
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)
        _ = try await source.games()

        server.revoke(deviceID: try XCTUnwrap(devices.all.first).id)

        await expectFailure(PackageSourceError.unauthorized) { _ = try await source.games() }
        XCTAssertTrue(devices.all.isEmpty)
    }

    func testRevokingCutsADownloadInProgress() async throws {
        server.stop()
        try ShareFixture.build(romfsBytes: 48 << 20, in: built, scratch: workspace)
        library.invalidate()
        port = try await server.start(port: 0, advertise: false)
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)
        let listing = try await source.listing(titleID: titleID)
        let total = UInt64(try XCTUnwrap(listing.files.first { $0.path == "romfs.img" }).size)

        let body = try await source.read(titleID: titleID, revision: listing.revision, path: "romfs.img", offset: 0)
        var iterator = body.chunks.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first)
        server.revoke(deviceID: try XCTUnwrap(devices.all.first).id)

        var received = UInt64(first?.count ?? 0)
        do {
            while let chunk = try await iterator.next() { received += UInt64(chunk.count) }
            XCTAssertLessThan(received, total, "the transfer stopped short")
        } catch {
            XCTAssertLessThan(received, total)
        }
    }

    // MARK: builds in flight

    func testARebuiltPackageAnswers409ToAnOldRevision() async throws {
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)
        let before = try await source.listing(titleID: titleID)

        try ShareFixture.build(version: "2.0.0", in: built, scratch: workspace)

        await expectFailure(PackageSourceError.changed) {
            _ = try await source.read(titleID: titleID, revision: before.revision, path: "romfs.img", offset: 0)
        }
    }

    func testAResumeAfterARebuildRestartsTheDownload() async throws {
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)
        let documents = workspace.appendingPathComponent("Documents", isDirectory: true)
        let downloader = PackageDownloader(documents: documents, availableSpace: { nil }, headroom: 0, maximumMinimumOS: OSVersion(major: 99))
        let game = try await source.games()[0]

        // The first plan is made, then the package is replaced before its files are read.
        let listing = try await source.listing(titleID: titleID)
        try ShareFixture.build(version: "2.0.0", in: built, scratch: workspace)
        await expectFailure(PackageSourceError.changed) {
            _ = try await source.read(titleID: titleID, revision: listing.revision, path: "package.json", offset: 0)
        }
        library.invalidate()
        let folder = try await downloader.download(game, from: source)

        XCTAssertEqual(try PackageVerifier.loadPackage(folder).version, "2.0.0")
    }

    // MARK: ranges

    func testARangeReturnsThePartAskedFor() async throws {
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)
        let listing = try await source.listing(titleID: titleID)
        let all = try Data(contentsOf: built.appendingPathComponent("\(titleID).nxgame/romfs.img"))

        let body = try await source.read(titleID: titleID, revision: listing.revision, path: "romfs.img", offset: 5000)
        var received = Data()
        for try await chunk in body.chunks { received.append(chunk) }

        XCTAssertEqual(body.offset, 5000)
        XCTAssertEqual(received, all.subdata(in: 5000..<all.count))
    }

    // MARK: staying inside the package

    func testTheListingNamesOnlyFilesOfThePackage() async throws {
        try Data("secret".utf8).write(to: built.appendingPathComponent("prod.keys"))
        // What may stand in a package folder without making it a broken one, and is no part of what is shared.
        for stray in [".DS_Store", ".signing.json", "._romfs.img", GameLayout.completeMarker] {
            try Data("x".utf8).write(to: built.appendingPathComponent("\(titleID).nxgame/\(stray)"))
        }
        library.invalidate()
        let mac = try await pair()
        let listing = try await PinnedHTTPSSource(mac).listing(titleID: titleID)

        XCTAssertTrue(listing.files.map(\.path).contains("package.json"))
        XCTAssertTrue(listing.files.map(\.path).contains("romfs.img"))
        XCTAssertTrue(listing.files.map(\.path).contains("romfs.blocks"), "the list of the image's blocks is served: updates fetch only what changed")
        for file in listing.files {
            XCTAssertTrue(file.path == "package.json" || file.path == "romfs.img" || file.path == "romfs.blocks" || file.path.hasPrefix("DmGame\(titleID).framework/") || file.path.hasPrefix("aoc/"), file.path)
        }
    }

    func testAFileInThePackageFolderThatIsNotListedIsNotServed() async throws {
        try Data("signed".utf8).write(to: built.appendingPathComponent("\(titleID).nxgame/.signing.json"))
        library.invalidate()
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)
        let listing = try await source.listing(titleID: titleID)

        for hidden in [".signing.json", ".complete", "save/progress.dat", "DmGame\(titleID).framework/_CodeSignature/CodeResources"] {
            await expectFailure(PackageSourceError.notFound) {
                _ = try await source.read(titleID: titleID, revision: listing.revision, path: hidden, offset: 0)
            }
        }
        await expectFailure(PackageSourceError.notFound) {
            _ = try await source.read(titleID: titleID, revision: listing.revision, path: "../prod.keys", offset: 0)
        }
    }

    func testALinkPutInPlaceOfARomfsImageAfterTheScanIsNotFollowed() async throws {
        let secret = workspace.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)
        let listing = try await source.listing(titleID: titleID)   // the library has scanned the package

        let romfs = built.appendingPathComponent("\(titleID).nxgame/romfs.img")
        try FileManager.default.removeItem(at: romfs)
        try FileManager.default.createSymbolicLink(at: romfs, withDestinationURL: secret)

        await expectFailure(PackageSourceError.notFound) {
            _ = try await source.read(titleID: titleID, revision: listing.revision, path: "romfs.img", offset: 0)
        }
    }

    func testAPackageFolderReplacedByALinkIsNotFollowed() async throws {
        let outside = workspace.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try ShareFixture.build(in: outside, scratch: workspace)
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)
        let listing = try await source.listing(titleID: titleID)

        let folder = built.appendingPathComponent("\(titleID).nxgame")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside.appendingPathComponent("\(titleID).nxgame"))

        await expectFailure(PackageSourceError.notFound) {
            _ = try await source.read(titleID: titleID, revision: listing.revision, path: "romfs.img", offset: 0)
        }
    }

    func testAPackageThatIsALinkIsNotListed() async throws {
        let linked = workspace.appendingPathComponent("elsewhere", isDirectory: true)
        try ShareFixture.build(titleID: "0100222000300000", in: linked, scratch: workspace)
        try FileManager.default.createSymbolicLink(at: built.appendingPathComponent("0100222000300000.nxgame"),
                                                   withDestinationURL: linked.appendingPathComponent("0100222000300000.nxgame"))
        library.invalidate()
        let mac = try await pair()

        let games = try await PinnedHTTPSSource(mac).games()

        XCTAssertEqual(games.map(\.titleID), [titleID])
    }

    func testAPackageWithAStrayFileAtItsRootIsNotShared() async throws {
        try Data("log".utf8).write(to: built.appendingPathComponent("\(titleID).nxgame/build.log"))
        try Data("x".utf8).write(to: built.appendingPathComponent("\(titleID).nxgame/save"))
        library.invalidate()
        let mac = try await pair()
        let source = PinnedHTTPSSource(mac)

        let games = try await source.games()
        XCTAssertTrue(games.isEmpty, "a package the verifier would refuse is not offered")
        await expectFailure(PackageSourceError.notFound) { _ = try await source.listing(titleID: titleID) }
    }

    func testABrokenPackageIsNotListed() async throws {
        try FileManager.default.removeItem(at: built.appendingPathComponent("\(titleID).nxgame/romfs.img"))
        library.invalidate()
        let mac = try await pair()

        let games = try await PinnedHTTPSSource(mac).games()

        XCTAssertTrue(games.isEmpty, "a package that is not whole is not offered")
    }

    // MARK: the key

    func testThePairingFileHoldsHashesAndTheKeyFileIsPrivate() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: keys.appendingPathComponent(ServerIdentity.keyFile).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: keys.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTheSameKeyIsLoadedAgainAndAResetMakesANewOne() throws {
        let again = try ServerIdentity.load(from: keys)
        XCTAssertEqual(again.pin, identity.pin)
        let fresh = try ServerIdentity.reset(in: keys)
        XCTAssertNotEqual(fresh.pin, identity.pin)
        XCTAssertEqual(try ServerIdentity.load(from: keys).pin, fresh.pin)
    }
}
