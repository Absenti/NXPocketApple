import Foundation
import XCTest

@testable import NXPMacKit

/// Which games' saves are copied by themselves: the ones whose listing changed since their newest copy, once the game
/// stopped writing them, and not more often than every half hour.
final class SaveWatchTests: XCTestCase {
    private let titleID = "010043600B6A6000"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stamp(_ secondsAgo: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func snapshot(saveSize: Int64 = 300, written secondsAgo: TimeInterval = 600, dates: Bool = true) -> PhoneSnapshot {
        let date = dates ? stamp(secondsAgo) : ""
        let files = [
            RemoteFile(path: "\(titleID)/package.json", size: 4652, date: stamp(90_000), isDirectory: false),
            RemoteFile(path: "\(titleID)/save", size: 128, date: date, isDirectory: true),
            RemoteFile(path: "\(titleID)/save/slot0.bin", size: saveSize, date: date, isDirectory: false),
            RemoteFile(path: "010051F0207B2000/package.json", size: 5000, date: stamp(90_000), isDirectory: false),
        ]
        let games = [PhoneGame(titleID: titleID, name: "South Park", version: "1.0", packageVersion: "v0"),
                     PhoneGame(titleID: "010051F0207B2000", name: "No saves yet", version: "1.0", packageVersion: "v0")]
        return PhoneSnapshot(deviceUDID: "X", bundleID: "dev.nxpocket.app.X", games: games, files: files)
    }

    private func summary(of snapshot: PhoneSnapshot) -> String {
        SaveWatch.listingDigest(snapshot.saveFiles(of: titleID))
    }

    func testTheSummaryIgnoresOrderAndFoldersButNotASizeOrADate() {
        let a = RemoteFile(path: "X/save/a", size: 1, date: "d1", isDirectory: false)
        let b = RemoteFile(path: "X/save/b", size: 2, date: "d1", isDirectory: false)
        let folder = RemoteFile(path: "X/save", size: 64, date: "d9", isDirectory: true)
        XCTAssertEqual(SaveWatch.listingDigest([a, b]), SaveWatch.listingDigest([folder, b, a]))
        var bigger = b
        bigger.size = 3
        XCTAssertNotEqual(SaveWatch.listingDigest([a, b]), SaveWatch.listingDigest([a, bigger]))
        var later = b
        later.date = "d2"
        XCTAssertNotEqual(SaveWatch.listingDigest([a, b]), SaveWatch.listingDigest([a, later]))
    }

    func testAGameWithNoCopyYetIsCopiedOnceItsSaveSettled() {
        var watch = SaveWatch()
        XCTAssertEqual(watch.due(snapshot(written: 600), newest: { _ in nil }, now: now), [titleID],
                       "the game without saves is never copied")
        XCTAssertEqual(watch.due(snapshot(written: 10), newest: { _ in nil }, now: now), [],
                       "a save written 10 s ago may be half written")
    }

    func testAnUnchangedGameIsNotCopiedAgain() {
        var watch = SaveWatch()
        let phone = snapshot()
        let newest = SaveWatch.Newest(date: now.addingTimeInterval(-86_400), listing: summary(of: phone))
        XCTAssertEqual(watch.due(phone, newest: { _ in newest }, now: now), [])
    }

    func testAChangedGameIsCopiedButNotWithinHalfAnHourOfItsNewestCopy() {
        var watch = SaveWatch()
        let old = summary(of: snapshot(saveSize: 200))
        let recent = SaveWatch.Newest(date: now.addingTimeInterval(-10 * 60), listing: old)
        XCTAssertEqual(watch.due(snapshot(), newest: { _ in recent }, now: now), [])
        let older = SaveWatch.Newest(date: now.addingTimeInterval(-31 * 60), listing: old)
        XCTAssertEqual(watch.due(snapshot(), newest: { _ in older }, now: now), [titleID])
    }

    func testACopyMadeBeforeTheSummaryExistedCountsAsChanged() {
        var watch = SaveWatch()
        let legacy = SaveWatch.Newest(date: now.addingTimeInterval(-86_400), listing: nil)
        XCTAssertEqual(watch.due(snapshot(), newest: { _ in legacy }, now: now), [titleID])
    }

    func testWithoutDatesASummarySeenTwiceInARowIsSettled() {
        var watch = SaveWatch()
        XCTAssertEqual(watch.due(snapshot(dates: false), newest: { _ in nil }, now: now), [],
                       "one look cannot tell a save being written")
        XCTAssertEqual(watch.due(snapshot(dates: false), newest: { _ in nil }, now: now), [titleID])
        XCTAssertEqual(watch.due(snapshot(saveSize: 301, dates: false), newest: { _ in nil }, now: now), [],
                       "it changed since the last look")
    }

    func testDevicectlDatesAreRead() {
        XCTAssertEqual(SaveWatch.parseDate("2026-11-11T00:13:24.000Z"), Date(timeIntervalSince1970: 1_794_356_004))
        XCTAssertEqual(SaveWatch.parseDate("2026-11-11T00:13:24Z"), Date(timeIntervalSince1970: 1_794_356_004))
        XCTAssertNil(SaveWatch.parseDate(""))
    }

    /// The real phone, read only: one listing, the games due, their copies into a scratch folder, then a second look
    /// that finds nothing due. Off by default: NXPOCKET_PHONE_LIVE=<scratch output folder> runs it on the paired iPhone.
    func testLiveCopiesTheChangedSavesOfThePairedPhoneOnce() throws {
        guard let folder = ProcessInfo.processInfo.environment["NXPOCKET_PHONE_LIVE"], !folder.isEmpty else {
            throw XCTSkip("set NXPOCKET_PHONE_LIVE to a scratch output folder to read the paired iPhone")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        let toolchain = ToolchainLocator.detect(engineRoot: nil)
        let device = try XCTUnwrap(try DeviceInventory.list(toolchain: toolchain).first { !$0.isSimulator && $0.canReceive })
        let snapshot = try DeviceLibrary(toolchain: toolchain).snapshot(on: device, bundleID: "dev.nxpocket.app")
        print("phone: \(snapshot.bundleID), \(snapshot.games.count) game(s), \(snapshot.files.count) entries")
        for game in snapshot.games {
            let saves = snapshot.saveFiles(of: game.titleID).filter { !$0.isDirectory }
            print("phone: \(game.titleID) \(game.name): \(saves.count) save file(s), newest write \(SaveWatch.newestWrite(saves).map { "\($0)" } ?? "none")")
        }
        var watch = SaveWatch()
        let due = watch.due(snapshot, newest: { SaveBackup.newest(of: $0, in: output) })
        print("phone: due now \(due)")
        let backup = SaveBackup(toolchain: toolchain)
        for titleID in due {
            let outcome = try backup.backUp(titleID: titleID, name: nil, snapshot: snapshot, device: device, outputFolder: output)
            print("phone: \(titleID) → \(outcome)")
        }
        var again = SaveWatch()
        XCTAssertEqual(again.due(snapshot, newest: { SaveBackup.newest(of: $0, in: output) }), [],
                       "the same listing is not copied twice")
    }

    // MARK: - Putting a copy back

    func testTheExportZipHoldsTheDatedFolderWithItsSavesAndNothingElse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nxpocket-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("2026-11-11 120000", isDirectory: true)
        try FileManager.default.createDirectory(at: backup.appendingPathComponent("save"), withIntermediateDirectories: true)
        try Data("slot".utf8).write(to: backup.appendingPathComponent("save/slot0.bin"))
        try Data("{}".utf8).write(to: backup.appendingPathComponent("backup.json"))
        // An extended attribute, as the Finder or a quarantine leaves one: it must not become a `._` entry.
        _ = backup.appendingPathComponent("backup.json").withUnsafeFileSystemRepresentation { path in
            setxattr(path, "com.example.test", "x", 1, 0, 0)
        }
        let archive = root.appendingPathComponent("copy.zip")
        try SaveExport.zip(backup: backup, to: archive)
        let listing = try ProcessRunner.capture(URL(fileURLWithPath: "/usr/bin/zipinfo"), ["-1", archive.path])
        XCTAssertEqual(listing.status, 0)
        let entries = Set(listing.lines.filter { !$0.isEmpty })
        XCTAssertTrue(entries.contains("2026-11-11 120000/backup.json"), "\(entries)")
        XCTAssertTrue(entries.contains("2026-11-11 120000/save/slot0.bin"), "\(entries)")
        XCTAssertFalse(entries.contains { $0.contains("__MACOSX") || $0.contains("/._") }, "\(entries)")
    }

    func testTheExportNameIsAPlainFileName() {
        let folder = URL(fileURLWithPath: "/x/2026-11-11 120000")
        XCTAssertEqual(SaveExport.archiveName(game: "South Park: The Stick/of Truth", backup: folder),
                       "South Park  The Stick of Truth saves 2026-11-11 120000.zip")
        XCTAssertEqual(SaveExport.archiveName(game: "", backup: folder), "Saves saves 2026-11-11 120000.zip")
    }
}
