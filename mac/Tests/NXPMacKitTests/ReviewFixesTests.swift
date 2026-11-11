import Foundation
import XCTest

@testable import NXPMacKit

/// What the external review of 2026-11-11 found in the launcher, each pinned once fixed.
final class ProcessRunnerTests: XCTestCase {
    /// Every line reaches onLine, in order, before onExit: the engine's reason and its game files line are its last.
    func testEveryLineArrivesInOrderBeforeTheEnd() throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "for i in $(seq 1 5000); do echo line$i; done; printf last"])
        let lock = NSLock()
        var seen: [String] = []
        var atExit = -1
        let ended = expectation(description: "exit")
        runner.onLine = { line in lock.lock(); seen.append(line); lock.unlock() }
        runner.onExit = { _ in lock.lock(); atExit = seen.count; lock.unlock(); ended.fulfill() }
        try runner.start()
        let result = runner.waitUntilExit()
        wait(for: [ended], timeout: 10)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(seen.count, 5001)
        XCTAssertEqual(atExit, 5001, "nothing arrives after the end")
        XCTAssertEqual(seen.first, "line1")
        XCTAssertEqual(seen.last, "last", "the last line without a newline is not lost")
        XCTAssertEqual(Array(seen[4995..<5000]), (4996...5000).map { "line\($0)" })
        XCTAssertEqual(result.lines.count, 5001)
    }

    func testTheResultKeepsTheLastLinesWithoutShiftingThem() {
        var ring = LineRing(capacity: 3)
        for index in 1...7 { ring.append("\(index)") }
        XCTAssertEqual(ring.lines, ["5", "6", "7"])
        var short = LineRing(capacity: 5)
        short.append("a"); short.append("b")
        XCTAssertEqual(short.lines, ["a", "b"])
    }
}

final class ToolchainOrderTests: XCTestCase {
    /// By name, "Xcode.app" came before "Xcode 27.2.app": a dot sorts after a space.
    func testXcodesAreTakenNewestFirstByTheirVersion() {
        let found: [(url: URL, version: [Int])] = [
            (URL(fileURLWithPath: "/Applications/Xcode.app"), [26, 4]),
            (URL(fileURLWithPath: "/Applications/Xcode 27.2.app"), [27, 2]),
            (URL(fileURLWithPath: "/Applications/Xcode-beta.app"), [27, 2, 1]),
            (URL(fileURLWithPath: "/Applications/Xcode 27.app"), [27]),
        ]
        XCTAssertEqual(ToolchainLocator.newestFirst(found).map(\.lastPathComponent),
                       ["Xcode-beta.app", "Xcode 27.2.app", "Xcode 27.app", "Xcode.app"])
    }
}

final class TransferWatchTests: XCTestCase {
    private let phone = Device(udid: "00008130-TEST", name: "iPhone", model: "iPhone 15 Pro", productType: "iPhone16,1",
                               osVersion: "27.0.1", isPhysical: true, isPaired: true, isConnected: true, transport: "wired")

    /// Only the entry being copied is listed: a file through its folder's own entries, a folder alone.
    func testTheWatchListsOnlyWhatIsBeingCopied() {
        let output = URL(fileURLWithPath: "/tmp/l.json")
        let file = DeviceTransfer.RemoteWatch(folder: "Documents/.incoming/ABC", name: "romfs.img", isDirectory: false) { _, _ in }
        let fileArguments = DeviceTransfer.watchArguments(file, device: phone, bundleID: "b", output: output)
        XCTAssertEqual(fileArguments[fileArguments.firstIndex(of: "--subdirectory")! + 1], "Documents/.incoming/ABC")
        XCTAssertTrue(fileArguments.contains("--no-recurse"))
        let folder = DeviceTransfer.RemoteWatch(folder: "Documents/.incoming/ABC", name: "DmGame.framework", isDirectory: true) { _, _ in }
        let folderArguments = DeviceTransfer.watchArguments(folder, device: phone, bundleID: "b", output: output)
        XCTAssertEqual(folderArguments[folderArguments.firstIndex(of: "--subdirectory")! + 1], "Documents/.incoming/ABC/DmGame.framework")
        XCTAssertFalse(folderArguments.contains("--no-recurse"))
        XCTAssertGreaterThanOrEqual(DeviceTransfer.watchInterval, 5)

        let listing = #"{"result":{"files":[{"metadata":{"size":96},"relativePath":"msl","resources":{"isDirectory":true}},{"metadata":{"size":1000},"relativePath":"DmGame","resources":{"isDirectory":false}},{"metadata":{"size":500},"relativePath":"msl/a.metallib","resources":{"isDirectory":false}}]}}"#
        XCTAssertEqual(DeviceTransfer.totalSize(inFilesListing: Data(listing.utf8)), 1500)
    }
}

final class WorkFolderTests: XCTestCase {
    /// The engine's build folders can live out of the dumps folder, through its own --work-dir.
    func testAWorkRootMovesTheBuildFolderOutOfTheDumps() throws {
        let base = FolderPackage(url: URL(fileURLWithPath: "/Volumes/Dumps/Game [0100AAAA00010000][v0].nsp"), bytes: 1,
                                 titles: [PackageTitle(titleID: 0x0100AAAA00010000, kind: .base, version: 0)], source: .name)
        let game = GameFolder.group([(package: base, contents: nil)]).games[0]
        XCTAssertEqual(try game.plan(.defaults(for: game)).workFolder.path, "/Volumes/Dumps/0100AAAA00010000_build")
        let elsewhere = try game.plan(.defaults(for: game), workRoot: URL(fileURLWithPath: "/Users/me/NXPocket work"))
        XCTAssertEqual(elsewhere.workFolder.path, "/Users/me/NXPocket work/0100AAAA00010000_build")
        XCTAssertEqual(elsewhere.inputFolder.deletingLastPathComponent(), elsewhere.workFolder, "the links live in it too")
    }
}
