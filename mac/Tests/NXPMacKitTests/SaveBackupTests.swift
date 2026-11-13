import Foundation
import XCTest

@testable import NXPMacKit

/// Copying a game's saves from the phone: only reads there, never a partial copy taken for a backup, the last ten
/// kept. devicectl is replaced by a function that plays the phone.
final class SaveBackupTests: XCTestCase {
    private var output: URL!
    private var commands: [[String]] = []
    private let phone = Device(udid: "00008130-TEST", name: "iPhone", model: "iPhone 15 Pro", productType: "iPhone16,1",
                               osVersion: "27.0.1", isPhysical: true, isPaired: true, isConnected: true, transport: "wired")
    private let titleID = "010043600B6A6000"

    override func setUpWithError() throws {
        output = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-saves-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        commands = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: output)
    }

    /// The phone's listing of `Documents/games`: a game with a `save` folder and a `save.bak` file, and another game.
    private func snapshot(_ extra: [RemoteFile] = []) -> PhoneSnapshot {
        let files = [
            RemoteFile(path: titleID, size: 384, date: "", isDirectory: true),
            RemoteFile(path: "\(titleID)/package.json", size: 4652, date: "", isDirectory: false),
            RemoteFile(path: "\(titleID)/romfs.img", size: 5_860_095_106, date: "", isDirectory: false),
            RemoteFile(path: "\(titleID)/save", size: 128, date: "", isDirectory: true),
            RemoteFile(path: "\(titleID)/save/slot0.bin", size: 300, date: "", isDirectory: false),
            RemoteFile(path: "\(titleID)/save/sub", size: 96, date: "", isDirectory: true),
            RemoteFile(path: "\(titleID)/save/sub/meta.dat", size: 20, date: "", isDirectory: false),
            RemoteFile(path: "\(titleID)/save.bak", size: 7, date: "", isDirectory: false),
            RemoteFile(path: "\(titleID)/temp/x", size: 5, date: "", isDirectory: false),
            RemoteFile(path: "010051F0207B2000/save/other.bin", size: 9, date: "", isDirectory: false),
        ] + extra
        return PhoneSnapshot(deviceUDID: phone.udid, bundleID: "dev.nxpocketapple.app.X", games: [], files: files)
    }

    /// Plays devicectl: a copy from the phone writes what the listing says, `short` bytes fewer for one file.
    private func backup(short: String? = nil, failing: String? = nil) -> SaveBackup {
        SaveBackup(fileManager: .default) { [unowned self] arguments in
            self.commands.append(arguments)
            let source = arguments[arguments.firstIndex(of: "--source")! + 1]
            let destination = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--destination")! + 1])
            if let failing, source.hasSuffix(failing) {
                return ProcessRunner.Result(status: 1, lines: ["ERROR: the device was disconnected"], isCancelled: false)
            }
            let remote = String(source.dropFirst("Documents/games/".count))
            for file in self.snapshot().files where !file.isDirectory && (file.path == remote || file.path.hasPrefix(remote + "/")) {
                let relative = file.path == remote ? "" : String(file.path.dropFirst(remote.count + 1))
                let target = relative.isEmpty ? destination : destination.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let size = Int(file.size) - (relative.hasSuffix(short ?? "\u{0}") ? 1 : 0)
                try Data(repeating: 1, count: size).write(to: target)
            }
            return ProcessRunner.Result(status: 0, lines: [], isCancelled: false)
        }
    }

    func testCopiesEverySaveEntryAndOnlyThem() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        guard case .saved(let record, let files, let bytes) = try backup().backUp(titleID: titleID, name: "South Park",
                                                                                 snapshot: snapshot(), device: phone,
                                                                                 outputFolder: output, now: date) else {
            return XCTFail("nothing saved")
        }
        XCTAssertEqual(files, 3)
        XCTAssertEqual(bytes, 327)
        XCTAssertEqual(record.folder.lastPathComponent, SaveBackup.folderDate.string(from: date))
        XCTAssertEqual(record.folder.deletingLastPathComponent().lastPathComponent, titleID)
        for path in ["save/slot0.bin", "save/sub/meta.dat", "save.bak", "backup.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.folder.appendingPathComponent(path).path), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.folder.appendingPathComponent("temp").path),
                       "temp is not a save")
        XCTAssertEqual(commands.map { $0[$0.firstIndex(of: "--source")! + 1] },
                       ["Documents/games/\(titleID)/save", "Documents/games/\(titleID)/save.bak"])
        XCTAssertEqual(SaveBackup.latest(in: output)[titleID], SaveBackup.folderDate.date(from: record.folder.lastPathComponent))
    }

    func testEveryCommandOnlyReadsThePhone() throws {
        _ = try backup().backUp(titleID: titleID, name: nil, snapshot: snapshot(), device: phone, outputFolder: output)
        let listing = DeviceLibrary.listArguments(device: phone, bundleID: "b", folder: "games", output: URL(fileURLWithPath: "/tmp/l.json"))
        let copy = DeviceLibrary.copyFromArguments(device: phone, bundleID: "b", source: "games/x", destination: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertFalse(commands.isEmpty)
        for command in commands + [listing, copy] {
            let verb = Array(command.prefix(4))
            XCTAssertTrue(verb == ["devicectl", "device", "copy", "from"] || verb == ["devicectl", "device", "info", "files"], "\(verb)")
            XCTAssertFalse(command.contains("--remove-existing-content") || command.contains("-r"),
                           "copy from has a remove flag too: never passed")
        }
    }

    func testACopyRecordsWhatThePhoneListedSoTheNextLookCanCompare() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try backup().backUp(titleID: titleID, name: "South Park", snapshot: snapshot(), device: phone,
                                outputFolder: output, now: date)
        let newest = try XCTUnwrap(SaveBackup.newest(of: titleID, in: output))
        XCTAssertEqual(newest.date, date)
        XCTAssertEqual(newest.listing, SaveWatch.listingDigest(snapshot().saveFiles(of: titleID)))
        let catalogue = SaveBackup.catalogue(in: output)
        XCTAssertEqual(catalogue.map(\.titleID), [titleID])
        XCTAssertEqual(catalogue.first?.name, "South Park")
        XCTAssertEqual(catalogue.first?.backups.count, 1)
    }

    func testACopyCutShortIsNeverKept() throws {
        XCTAssertThrowsError(try backup(short: "meta.dat").backUp(titleID: titleID, name: nil, snapshot: snapshot(),
                                                                  device: phone, outputFolder: output)) { error in
            XCTAssertTrue("\(error)".contains("did not arrive whole"), "\(error)")
        }
        XCTAssertThrowsError(try backup(failing: "save.bak").backUp(titleID: titleID, name: nil, snapshot: snapshot(),
                                                                    device: phone, outputFolder: output))
        let left = try FileManager.default.contentsOfDirectory(atPath: SaveBackup.folder(of: titleID, in: output).path)
        XCTAssertEqual(left, [], "neither the partial copy nor a dated folder stays")
        XCTAssertNil(SaveBackup.latest(in: output)[titleID])
    }

    func testAGameWithoutSavesWritesNothing() throws {
        let empty = PhoneSnapshot(deviceUDID: phone.udid, bundleID: "b", games: [], files: [
            RemoteFile(path: "\(titleID)/save", size: 64, date: "", isDirectory: true),
        ])
        XCTAssertEqual(try backup().backUp(titleID: titleID, name: nil, snapshot: empty, device: phone, outputFolder: output),
                       .nothingToSave)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SaveBackup.root(in: output).path))
    }

    func testKeepsTheTenNewestAndRemovesALeftoverPartialCopy() throws {
        let folder = SaveBackup.folder(of: titleID, in: output)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for day in 0..<11 {
            let made = folder.appendingPathComponent(SaveBackup.folderDate.string(from: start.addingTimeInterval(Double(day) * 86_400)))
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: made.appendingPathComponent(SaveBackup.manifestName))
        }
        // The user's own folders, one of them named like a backup: neither counted nor deleted.
        let usersCopy = SaveBackup.folderDate.string(from: start.addingTimeInterval(-86_400))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(usersCopy), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("\(usersCopy) before the boss"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".partial-OLD"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("my notes"), withIntermediateDirectories: true)
        XCTAssertEqual(SaveBackup.backups(of: titleID, in: output).count, 11, "only the folders a backup made are backups")

        let now = start.addingTimeInterval(20 * 86_400)
        _ = try backup().backUp(titleID: titleID, name: nil, snapshot: snapshot(), device: phone, outputFolder: output, now: now)
        let kept = SaveBackup.backups(of: titleID, in: output)
        XCTAssertEqual(kept.count, SaveBackup.keep)
        XCTAssertEqual(kept.first?.folder.lastPathComponent, SaveBackup.folderDate.string(from: now))
        XCTAssertEqual(kept.last?.folder.lastPathComponent, SaveBackup.folderDate.string(from: start.addingTimeInterval(2 * 86_400)))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        for mine in ["my notes", usersCopy, "\(usersCopy) before the boss"] {
            XCTAssertTrue(names.contains(mine), "\(mine) is the user's: never rotated away")
        }
        XCTAssertFalse(names.contains(".partial-OLD"))
    }

    func testABackupFolderNameIsADateAndNothingElse() {
        XCTAssertNotNil(SaveBackup.date(ofFolderNamed: "2026-11-11 120000"))
        XCTAssertNotNil(SaveBackup.date(ofFolderNamed: "2026-11-11 120000 2"), "a second backup in the same second")
        XCTAssertNil(SaveBackup.date(ofFolderNamed: "2026-11-11 120000 my copy"))
        XCTAssertNil(SaveBackup.date(ofFolderNamed: "2026-11-11 120000x"))
        XCTAssertNil(SaveBackup.date(ofFolderNamed: "2026-13-45 999999"))
    }

    /// The title ID names a folder on the Mac: a phone's package.json saying "../.." must not reach a path.
    func testATitleIDFromThePhoneIsCheckedBeforeItBecomesAPath() {
        XCTAssertThrowsError(try backup().backUp(titleID: "../../Library", name: nil, snapshot: snapshot(), device: phone,
                                                 outputFolder: output))
        XCTAssertTrue(commands.isEmpty)
        let forged = #"{"title_id":"../../Library","name":"x","version":"1","package_version":"v0"}"#
        XCTAssertNil(DeviceLibrary.phoneGame(packageJSON: Data(forged.utf8)))
        let other = #"{"title_id":"0100AAAA00010000","name":"x","version":"1","package_version":"v0"}"#
        XCTAssertNil(DeviceLibrary.phoneGame(packageJSON: Data(other.utf8), folder: "010043600B6A6000"),
                     "a package.json that names another game than its folder")
        XCTAssertEqual(DeviceLibrary.phoneGame(packageJSON: Data(other.utf8), folder: "0100aaaa00010000")?.titleID, "0100AAAA00010000")
    }

    func testTheSnapshotGivesOneGamesSaveEntries() {
        XCTAssertEqual(snapshot().saveFiles(of: titleID).map(\.path), [
            "\(titleID)/save", "\(titleID)/save/slot0.bin", "\(titleID)/save/sub", "\(titleID)/save/sub/meta.dat", "\(titleID)/save.bak",
        ])
        XCTAssertEqual(snapshot().saveFiles(of: "010051F0207B2000").map(\.path), ["010051F0207B2000/save/other.bin"])
    }
}

/// A phone whose app has not opened since it was installed has no `Documents/games` yet: no game, not an error.
final class PhoneListingTests: XCTestCase {
    func testADocumentsListingWithoutGamesMeansNoGame() {
        let documents = [
            RemoteFile(path: ".incoming", size: 128, date: "", isDirectory: true),
            RemoteFile(path: "keep.txt", size: 5, date: "", isDirectory: false),
        ]
        XCTAssertEqual(DeviceLibrary.gamesEntries(ofDocumentsListing: documents), [])
        let withGames = documents + [RemoteFile(path: "games/010043600B6A6000/package.json", size: 4652, date: "d", isDirectory: false)]
        XCTAssertEqual(DeviceLibrary.gamesEntries(ofDocumentsListing: withGames).map(\.path), ["010043600B6A6000/package.json"])
    }
}
