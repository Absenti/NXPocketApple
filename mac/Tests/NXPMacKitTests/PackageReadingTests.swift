import Foundation
import XCTest

@testable import NXPMacKit
@testable import NXPMacModel

/// Reading a package with the keys, on packages built by `SwitchFixtures`: what the user's SuperXCI needed, since its
/// name carries no title ID and it holds a base game, its update and its DLC in one file.
final class PackageReadingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-packages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testReadsTheTitlesOfAMergedPackageWhoseNameSaysNothing() throws {
        let control = (0..<16).map { UInt8($0) }
        let url = try write("Merged Game (v1.1.0 & DLC).nsp", SwitchFixtures.nsp([
            .init(titleID: 0x0100A9D01C446000, version: 0, type: 0x80, control: nil),
            .init(titleID: 0x0100A9D01C446800, version: 65_536, type: 0x81, control: control),
            .init(titleID: 0x0100A9D01C447001, version: 0, type: 0x82, control: nil),
        ], name: "Merged Game", displayVersion: "1.1.0"))
        let contents = try PackageInspector.inspect(url, keys: SwitchFixtures.keys)
        XCTAssertEqual(contents.titles, [
            PackageTitle(titleID: 0x0100A9D01C446000, kind: .base, version: 0),
            PackageTitle(titleID: 0x0100A9D01C446800, kind: .update, version: 65_536),
            PackageTitle(titleID: 0x0100A9D01C447001, kind: .dlc, version: 0),
        ])
        XCTAssertEqual(contents.name, "Merged Game", "from the control data, through the ticket's title key")
        XCTAssertEqual(contents.displayVersion, "1.1.0")
        XCTAssertEqual(contents.icon.map { [UInt8]($0.prefix(2)) }, [0xFF, 0xD8])
        XCTAssertTrue(contents.notes.isEmpty, "\(contents.notes)")

        let listing = GameFolder.scan(folder) { GameFolder.identify($0, bytes: $1, keys: SwitchFixtures.keys) }
        XCTAssertEqual(listing.games.map(\.titleID), ["0100A9D01C446000"])
        XCTAssertEqual(listing.games[0].name, "Merged Game")
        XCTAssertEqual(listing.games[0].updates.map(\.version), [65_536])
    }

    func testAWrongHeaderKeyIsSaidSoAndTheNameStillServes() throws {
        let url = try write("Game [0100AAAA00010000][v0].nsp", SwitchFixtures.nsp([
            .init(titleID: 0x0100AAAA00010000, version: 0, type: 0x80, control: nil),
        ]))
        let wrong = try SwitchKeys.parse("header_key = \(String(repeating: "ab", count: 32))")
        XCTAssertThrowsError(try PackageInspector.inspect(url, keys: wrong)) { error in
            XCTAssertTrue("\(error)".contains("header_key"), "\(error)")
        }
        guard case .success(let found) = GameFolder.identify(url, bytes: 1, keys: wrong) else {
            return XCTFail("the name's title ID should have been used")
        }
        XCTAssertEqual(found.package.source, .name)
        XCTAssertEqual(found.package.titles.first?.titleID, 0x0100AAAA00010000)
    }

    func testTheKeysNeverShowInADescriptionOrAnError() throws {
        let keys = SwitchFixtures.keys
        let secret = hexString(SwitchFixtures.headerKey)
        XCTAssertFalse("\(keys)".contains(secret))
        XCTAssertFalse(String(reflecting: keys).contains(secret))
        XCTAssertThrowsError(try SwitchKeys.parse("titlekek_00 = \(secret.prefix(32))")) { error in
            XCTAssertFalse("\(error)".contains(secret.prefix(32)), "a parse error names no key")
        }
        XCTAssertThrowsError(try SwitchKeys.load(from: folder.appendingPathComponent("missing/prod.keys"))) { error in
            XCTAssertFalse("\(error)".contains(self.folder.path), "an error names prod.keys, never its path")
        }
    }

    func testNintendoXTSNumbersSectorsBigEndian() throws {
        let key = (0..<32).map { UInt8($0) }
        let plain = (0..<0x400).map { UInt8($0 & 0xFF) }
        let encrypted = try SwitchCrypto.xtsEncrypt(plain, key: key, firstSector: 0)
        XCTAssertEqual(try SwitchCrypto.xtsDecrypt(encrypted, key: key, firstSector: 0), plain)
        XCTAssertEqual(Array(try SwitchCrypto.xtsDecrypt(Array(encrypted[0x200...]), key: key, firstSector: 1)), Array(plain[0x200...]),
                       "a sector decrypts alone with its own number")
        XCTAssertNotEqual(try SwitchCrypto.xtsDecrypt(encrypted, key: key, firstSector: 1), plain)
    }

    /// Bytes from a file never reach a trap: a wrong size is an error, where it used to stop the whole launcher.
    func testTheCryptoRefusesWrongSizesInsteadOfCrashing() {
        XCTAssertThrowsError(try SwitchCrypto.ecb([1, 2, 3], key: Array(repeating: 0, count: 16), encrypt: false))
        XCTAssertThrowsError(try SwitchCrypto.ecb(Array(repeating: 0, count: 16), key: [1], encrypt: false))
        XCTAssertThrowsError(try SwitchCrypto.ctr([1], key: Array(repeating: 0, count: 16), counter: [0]))
        XCTAssertThrowsError(try SwitchCrypto.xtsDecrypt(Array(repeating: 0, count: 100), key: Array(repeating: 0, count: 32), firstSector: 0))
    }

    /// An offset read from a file that adds up past 2^64 is a damaged package, not a crash in the middle of a scan.
    func testAnOffsetPastTheEndOfAnyFileIsADamagedPackage() throws {
        XCTAssertThrowsError(try offsetSum(UInt64.max, 16))
        XCTAssertEqual(try offsetSum(1, 2, 3), 6)
        var pfs0 = Array("PFS0".utf8) + SwitchFixtures.le(1, 4) + SwitchFixtures.le(16, 4) + [0, 0, 0, 0]
        pfs0 += SwitchFixtures.le(UInt64.max - 4, 8) + SwitchFixtures.le(1, 8) + SwitchFixtures.le(0, 4) + [0, 0, 0, 0]
        pfs0 += Array("x.cnmt.nca".utf8) + Array(repeating: 0, count: 6)
        let url = try write("Forged [0100AAAA00010000][v0].nsp", Data(pfs0))
        XCTAssertThrowsError(try PackageInspector.inspect(url, keys: SwitchFixtures.keys))
        guard case .success = GameFolder.identify(url, bytes: 1, keys: SwitchFixtures.keys) else {
            return XCTFail("the name still identifies the package")
        }
    }

    func testCounterModeCarriesAcrossTheLowHalf() {
        var counter: [UInt8] = Array(repeating: 0, count: 8) + Array(repeating: 0xFF, count: 8)
        SwitchCrypto.increment(&counter)
        XCTAssertEqual(counter, [0, 0, 0, 0, 0, 0, 0, 1] + Array(repeating: 0, count: 8))
    }
}

/// The bars: the build's, the queue item's and the queue's.
final class ProgressTests: XCTestCase {
    func testTheWholeBuildMovesThroughStagesThatHaveNoCount() {
        var progress = BuildProgress()
        let lines = [
            #"{"ev":"stage","k":1,"n":4,"name":"build nx_extract","step":""}"#,
            #"{"ev":"stage_end","k":1,"name":"build nx_extract","ok":true,"summary":""}"#,
            #"{"ev":"stage","k":2,"n":4,"name":"extract v0","step":""}"#,
        ]
        for line in lines { progress.apply(EngineEventParser.parse(line: line)) }
        XCTAssertEqual(progress.overall, 0.25, accuracy: 0.0001)
        XCTAssertFalse(progress.stageHasCount)
        progress.apply(EngineEventParser.parse(line: #"{"ev":"progress","k":2,"name":"extract v0","done":50,"total":100,"frac":0.5}"#))
        XCTAssertEqual(progress.overall, 0.375, accuracy: 0.0001)
        XCTAssertTrue(progress.stageHasCount)
        progress.apply(EngineEventParser.parse(line: #"{"ev":"stage","k":2,"n":5,"name":"heap check","step":""}"#))
        XCTAssertEqual(progress.overall, 0.375, accuracy: 0.0001, "a stage added on the way never pulls the bar back")
    }

    func testAQueueItemSharesItsBarBetweenBuildAndSend() {
        let plan = BuildPlan(titleID: "0100AAAA00010000", name: "A", inputs: [], version: 0, packageVersion: nil,
                             dlcTitleIDs: [], workFolder: URL(fileURLWithPath: "/tmp/w"), compressed: false)
        var item = QueueItem(titleID: "0100AAAA00010000", name: "A", job: .build(plan, sendTo: "UDID"))
        XCTAssertEqual(item.fraction, 0)
        item.phase = .building(stage: "2/4", stageFraction: nil, overall: 0.5, detail: "")
        XCTAssertEqual(item.fraction, 0.3375, accuracy: 0.0001)
        item.phase = .packing(fraction: 1, detail: "")
        XCTAssertEqual(item.fraction, 0.75, accuracy: 0.0001)
        item.phase = .sending(fraction: 0.5, detail: "")
        XCTAssertEqual(item.fraction, 0.875, accuracy: 0.0001)
        item.phase = .failed("x")
        XCTAssertEqual(item.fraction, 1, "a finished item counts in full in the queue's bar")

        var send = QueueItem(titleID: "0100AAAA00010000", name: "A", job: .send(package: URL(fileURLWithPath: "/tmp/a"), to: "U"))
        send.phase = .sending(fraction: 0.4, detail: "")
        XCTAssertEqual(send.fraction, 0.4, accuracy: 0.0001)
    }
}

/// What the phone says: its listing of `Documents/games` and a game's `package.json`.
final class DeviceLibraryTests: XCTestCase {
    func testFindsEachInstalledGamesPackageFile() {
        let json = #"""
        {"result":{"files":[
          {"metadata":{"size":384,"lastModDate":"2026-11-11T00:13:24.000Z"},"relativePath":"010043600B6A6000","resources":{"isDirectory":true}},
          {"metadata":{"size":4652,"lastModDate":"2026-11-11T00:13:20.000Z"},"relativePath":"010043600B6A6000/package.json","resources":{"isDirectory":false}},
          {"metadata":{"size":9,"lastModDate":"2026-11-11T00:13:20.000Z"},"relativePath":"010043600B6A6000/.complete","resources":{"isDirectory":false}},
          {"metadata":{"size":100,"lastModDate":"2026-11-11T00:13:20.000Z"},"relativePath":"010043600B6A6000/DmGame.framework/package.json","resources":{"isDirectory":false}},
          {"metadata":{"size":5000,"lastModDate":"2026-11-11T01:40:00.000Z"},"relativePath":"010051F0207B2000/package.json","resources":{"isDirectory":false}}
        ]}}
        """#
        let found = DeviceLibrary.packageFiles(inFilesListing: Data(json.utf8))
        XCTAssertEqual(found.map(\.titleID), ["010043600B6A6000", "010051F0207B2000"])
        XCTAssertEqual(found[0].size, 4652)
    }

    func testReadsAPackageJSON() {
        let json = #"{"schema":1,"title_id":"010043600b6a6000","name":"South Park","version":"1.0.0","package_version":"v0","files":[]}"#
        XCTAssertEqual(DeviceLibrary.phoneGame(packageJSON: Data(json.utf8)),
                       PhoneGame(titleID: "010043600B6A6000", name: "South Park", version: "1.0.0", packageVersion: "v0"))
    }

    func testAFoldersProgressIsTheSumOfItsFilesSoFar() {
        let json = #"{"result":{"files":[{"metadata":{"size":384},"relativePath":"DmGame.framework","resources":{"isDirectory":true}},{"metadata":{"size":1000},"relativePath":"DmGame.framework/DmGame","resources":{"isDirectory":false}},{"metadata":{"size":96},"relativePath":"DmGame.framework/msl","resources":{"isDirectory":true}},{"metadata":{"size":500},"relativePath":"DmGame.framework/msl/a.metallib","resources":{"isDirectory":false}},{"metadata":{"size":7},"relativePath":"DmGame.frameworkX","resources":{"isDirectory":false}}]}}"#
        XCTAssertEqual(DeviceTransfer.remoteSize(inFilesListing: Data(json.utf8), relativePath: "DmGame.framework"), 1500)
    }
}
