import Darwin
import XCTest
@testable import NXPMacKit
@testable import NXPMacModel

/// A cancelled build takes away what it made, and only that: the work folder holds hours of earlier work.
final class BuildFootprintTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("footprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.root) }
    }

    private func write(_ path: String, _ text: String = "x", in base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ path: String, in base: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (base ?? root).appendingPathComponent(path).path)
    }

    private func read(_ path: String, in base: URL? = nil) -> String? {
        (try? String(contentsOf: (base ?? root).appendingPathComponent(path), encoding: .utf8))
    }

    func testAFolderThatDidNotExistIsTheBuildsOwnAndGoesWhole() throws {
        let work = root.appendingPathComponent("0100152000022000_build", isDirectory: true)
        let footprint = BuildFootprint.capture(work)
        XCTAssertFalse(footprint.existedBefore)
        try write("extract/v1.partial/RomFS.img", String(repeating: "r", count: 4000), in: work)
        try write("shader/cache/a.metallib", "m", in: work)
        let removal = footprint.removeCreated()
        XCTAssertTrue(removal.wholeFolder)
        XCTAssertGreaterThanOrEqual(removal.items, 5, "the folder, extract, v1.partial, RomFS.img, shader, cache, a.metallib")
        XCTAssertGreaterThanOrEqual(removal.bytes, 4001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    /// The case that matters: the folder holds the shader cache of a game built before, and a rebuild is cancelled.
    func testWhatWasThereBeforeIsKeptAndOnlyWhatAppearedGoes() throws {
        let work = root.appendingPathComponent("0100152000022000_build", isDirectory: true)
        try write("extract/v1441792/RomFS.img", "THE-EXTRACTION", in: work)
        try write("shader/cache/old1.metallib", "old1", in: work)
        try write("shader/cache/old2.metallib", "old2", in: work)
        try write("profile/0100152000022000/game.tsv", "profile", in: work)
        let footprint = BuildFootprint.capture(work)
        XCTAssertTrue(footprint.existedBefore)
        XCTAssertTrue(footprint.isSafe)

        // The cancelled run: new files inside a folder that was there, a new folder, a partial extraction.
        try write("shader/cache/new1.metallib", "new1", in: work)
        try write("shader/cache/new2.metallib", "new2", in: work)
        try write("extract/v1507328.partial/RomFS.img", String(repeating: "p", count: 3000), in: work)
        try write("logs/build.log", "log", in: work)

        let removal = footprint.removeCreated()
        XCTAssertFalse(removal.wholeFolder)
        XCTAssertEqual(read("extract/v1441792/RomFS.img", in: work), "THE-EXTRACTION")
        XCTAssertEqual(read("shader/cache/old1.metallib", in: work), "old1")
        XCTAssertEqual(read("shader/cache/old2.metallib", in: work), "old2")
        XCTAssertEqual(read("profile/0100152000022000/game.tsv", in: work), "profile")
        XCTAssertFalse(exists("shader/cache/new1.metallib", in: work))
        XCTAssertFalse(exists("shader/cache/new2.metallib", in: work))
        XCTAssertFalse(exists("extract/v1507328.partial", in: work), "a new folder goes with all it holds")
        XCTAssertFalse(exists("logs", in: work))
        XCTAssertTrue(exists("shader/cache", in: work), "the folder that was there stays")
        XCTAssertEqual(removal.items, 6, "new1, new2, the partial folder and its file, logs and its file")
        XCTAssertGreaterThanOrEqual(removal.bytes, 3000)
    }

    func testAFileRewrittenInPlaceIsNotGivenBackNorRemoved() throws {
        let work = root.appendingPathComponent("0100AAAA00010000_build", isDirectory: true)
        try write("shader/index.json", "{\"a\":1}", in: work)
        let footprint = BuildFootprint.capture(work)
        try write("shader/index.json", "{\"a\":1,\"b\":2}", in: work)
        footprint.removeCreated()
        XCTAssertEqual(read("shader/index.json", in: work), "{\"a\":1,\"b\":2}", "it was there before: left as the build wrote it")
    }

    func testNothingOutsideTheFolderIsEverTouchedAndALinkIsRemovedAsALink() throws {
        let elsewhere = root.appendingPathComponent("dumps", isDirectory: true)
        try write("game.xci", "THE-DUMP", in: elsewhere)
        try write("keep/other.txt", "other", in: elsewhere)
        let work = root.appendingPathComponent("0100AAAA00010000_build", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let footprint = BuildFootprint.capture(work)
        // What `BuildInputs.prepare` does: links to the dump, and a link to a whole folder.
        try FileManager.default.createDirectory(at: work.appendingPathComponent("inputs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("inputs/game.xci"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("game.xci"))
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("inputs/folder"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("keep"))
        let removal = footprint.removeCreated()
        XCTAssertFalse(removal.wholeFolder, "the folder existed (empty) before: it stays, what was added goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
        XCTAssertFalse(exists("inputs", in: work))
        XCTAssertEqual(removal.items, 3, "inputs and its two links, counted as links")
        XCTAssertEqual(read("game.xci", in: elsewhere), "THE-DUMP", "the dump the link pointed at is intact")
        XCTAssertEqual(read("keep/other.txt", in: elsewhere), "other", "a link to a folder is not walked through")
    }

    func testALinkAddedToAnExistingFolderGoesButWhatItPointsAtStays() throws {
        let elsewhere = root.appendingPathComponent("dumps", isDirectory: true)
        try write("keep/other.txt", "other", in: elsewhere)
        let work = root.appendingPathComponent("0100AAAA00010000_build", isDirectory: true)
        try write("a.txt", "a", in: work)
        let footprint = BuildFootprint.capture(work)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("link"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("keep"))
        footprint.removeCreated()
        XCTAssertFalse(exists("link", in: work))
        XCTAssertEqual(read("a.txt", in: work), "a")
        XCTAssertEqual(read("keep/other.txt", in: elsewhere), "other")
    }

    func testAFolderNotCalledBuildIsNeverCleaned() throws {
        let precious = root.appendingPathComponent("Documents", isDirectory: true)
        try write("mine.txt", "mine", in: precious)
        let footprint = BuildFootprint.capture(precious)
        XCTAssertFalse(footprint.isSafe)
        try write("new.txt", "new", in: precious)
        XCTAssertTrue(footprint.removeCreated().isEmpty)
        XCTAssertEqual(read("mine.txt", in: precious), "mine")
        XCTAssertEqual(read("new.txt", in: precious), "new")
    }

    func testALinkInPlaceOfTheFolderIsNeverCleanedThrough() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try write("data.txt", "data", in: real)
        let work = root.appendingPathComponent("0100AAAA00010000_build")
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: real)
        let footprint = BuildFootprint.capture(work)
        XCTAssertFalse(footprint.isSafe)
        XCTAssertTrue(footprint.removeCreated().isEmpty)
        XCTAssertEqual(read("data.txt", in: real), "data")
    }

    func testNothingCreatedMeansNothingRemoved() throws {
        let work = root.appendingPathComponent("0100AAAA00010000_build", isDirectory: true)
        try write("a.txt", "a", in: work)
        let footprint = BuildFootprint.capture(work)
        XCTAssertTrue(footprint.removeCreated().isEmpty)
        XCTAssertEqual(read("a.txt", in: work), "a")
        let none = BuildFootprint.capture(root.appendingPathComponent("0100BBBB00010000_build"))
        XCTAssertTrue(none.removeCreated().isEmpty, "the folder was never made: nothing to remove")
    }
}

/// Cancelling stops everything the process started, not only the process.
final class CancelTreeTests: XCTestCase {
    private func state(_ pid: pid_t) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runningTree(_ script: String) throws -> (runner: ProcessRunner, tree: [pid_t]) {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        try runner.start()
        var tree: [pid_t] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            tree = ProcessTree.descendants(of: runner.processIdentifier)
            if tree.count >= 4 { break }
            usleep(50_000)
        }
        XCTAssertGreaterThanOrEqual(tree.count, 4, "the shell, a child shell and two sleepers")
        addTeardownBlock { for pid in tree { kill(pid, SIGKILL) } }
        return (runner, tree)
    }

    func testCancelStopsTheChildrenAndTheirChildrenToo() throws {
        let (runner, tree) = try runningTree("sh -c 'sleep 60 & sleep 60 & wait' & sleep 60 & wait")
        runner.cancel()
        let result = runner.waitUntilExit()
        XCTAssertTrue(result.isCancelled)
        XCTAssertTrue(runner.waitUntilTreeGone(timeout: 10), "something the build started is still running after a cancel")
        for pid in tree { XCTAssertTrue(state(pid).isEmpty || state(pid).hasPrefix("Z"), "\(pid) is still there: \(state(pid))") }
    }

    func testCancelOfAPausedBuildStopsTheTreeToo() throws {
        let (runner, tree) = try runningTree("sh -c 'sleep 60 & sleep 60 & wait' & sleep 60 & wait")
        XCTAssertTrue(runner.pause())
        runner.cancel()
        runner.waitUntilExit()
        XCTAssertTrue(runner.waitUntilTreeGone(timeout: 10))
        for pid in tree { XCTAssertTrue(state(pid).isEmpty || state(pid).hasPrefix("Z"), "\(pid) survived: \(state(pid))") }
    }

    func testAProcessThatIgnoresTermIsKilledAfterTheGrace() throws {
        let (runner, tree) = try runningTree("trap '' TERM; sh -c 'trap \"\" TERM; sleep 60 & sleep 60 & wait' & sleep 60 & wait")
        runner.cancel()
        XCTAssertTrue(runner.waitUntilTreeGone(timeout: ProcessRunner.killGrace + 6), "SIGKILL after the grace")
        for pid in tree { XCTAssertTrue(state(pid).isEmpty || state(pid).hasPrefix("Z"), "\(pid): \(state(pid))") }
    }

    func testWaitingForATreeThatWasNeverCancelledReturnsAtOnce() throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"])
        try runner.start()
        runner.waitUntilExit()
        XCTAssertTrue(runner.waitUntilTreeGone(timeout: 1))
    }

    func testAnIdentityIsNotAnotherProcessThatTookTheNumber() {
        let me = ProcessTree.members(of: getpid()).first
        XCTAssertNotNil(me)
        XCTAssertTrue(ProcessTree.isAlive(me!))
        XCTAssertFalse(ProcessTree.isAlive(ProcessTree.Member(pid: me!.pid, started: me!.started &+ 1)),
                       "the same id with another start time is another process")
    }
}

final class CancelledItemTests: XCTestCase {
    func testACancelledBuildSaysWhatBecameOfItsWork() {
        var item = QueueItem(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe",
                             job: .send(package: URL(fileURLWithPath: "/tmp/x"), to: "udid"))
        item.phase = .cancelled
        XCTAssertEqual(item.status, "cancelled")
        item.note = "removed 3.2 GB this build had created"
        XCTAssertEqual(item.status, "cancelled · removed 3.2 GB this build had created")
    }
}

/// The kernel's id is not a process anyone may signal.
final class ProcessTreeGuardTests: XCTestCase {
    func testTheKernelAndLaunchdAreNeverATree() {
        for pid: pid_t in [0, 1, -1, -500] {
            XCTAssertTrue(ProcessTree.children(of: pid).isEmpty, "\(pid)")
            XCTAssertTrue(ProcessTree.descendants(of: pid).isEmpty, "\(pid)")
            XCTAssertTrue(ProcessTree.members(of: pid).isEmpty, "\(pid)")
            XCTAssertTrue(ProcessTree.stop(rootedAt: pid).isEmpty, "\(pid)")
            XCTAssertNil(ProcessTree.startTime(of: pid), "\(pid)")
        }
        // Even a hand-made member of such an id is never signalled.
        ProcessTree.send(SIGSTOP, to: [ProcessTree.Member(pid: 0, started: 0), ProcessTree.Member(pid: 1, started: 0)])
        ProcessTree.resume([0, 1, -1])
    }

    func testARunnerThatHasExitedHasNoTreeToPauseOrCancel() throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"])
        try runner.start()
        runner.waitUntilExit()
        XCTAssertEqual(runner.processIdentifier, 0)
        XCTAssertTrue(ProcessTree.members(of: runner.processIdentifier).isEmpty, "not the whole machine")
        XCTAssertFalse(runner.pause())
        runner.cancel()
        XCTAssertTrue(runner.waitUntilTreeGone(timeout: 1))
    }
}

/// The Dragon Quest build of 2026-11-13: the engine's files were replaced at 14:00, in the middle of an hour of shader
/// compiling, and the next stage failed with "no iOS shader libraries …/b-0c434f1b68df" and no hint why.
final class EngineIdentityTests: XCTestCase {
    private func engine(stamp: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("# engine".utf8).write(to: root.appendingPathComponent("scripts/build_ipa_from_nsp.py"))
        if let stamp { try Data(stamp.utf8).write(to: root.appendingPathComponent(".git/nx2apple-stamp")) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private let old = "nx2apple-engine 1\npin f25fa9562ee96d06f1e6412dbb91aab2b7035ec1\nkey aaa\nhead 111\n"
    private let new = "nx2apple-engine 1\npin 81906931262fb25d774cce8bca2db8926439e5a2\nkey bbb\nhead 222\n"

    func testTheStampNamesTheEngine() throws {
        let identity = EngineIdentity.read(try engine(stamp: old))
        XCTAssertEqual(identity, .stamp(old))
        XCTAssertEqual(identity.pin, "f25fa956")
        XCTAssertEqual(EngineIdentity.read(try engine(stamp: new)).pin, "81906931")
    }

    func testAnEngineWithoutAStampIsKnownByItsScript() throws {
        guard case .modified = EngineIdentity.read(try engine(stamp: nil)) else { return XCTFail("expected the script's date") }
        XCTAssertEqual(EngineIdentity.read(URL(fileURLWithPath: "/nonexistent-engine")), .unknown)
    }

    func testAChangedEngineIsSaidWithTheTwoVersions() throws {
        let note = try XCTUnwrap(EngineIdentity.changeNote(from: EngineIdentity.read(try engine(stamp: old)),
                                                          to: EngineIdentity.read(try engine(stamp: new))))
        XCTAssertTrue(note.contains("from nxnative f25fa956 to 81906931"), note)
        XCTAssertTrue(note.contains("start the build again"), note)
    }

    func testNothingIsClaimedWhenTheEngineIsTheSameOrCannotBeRead() throws {
        let same = EngineIdentity.read(try engine(stamp: old))
        XCTAssertNil(EngineIdentity.changeNote(from: same, to: same))
        XCTAssertNil(EngineIdentity.changeNote(from: .unknown, to: same), "no first look: nothing to compare")
        XCTAssertNil(EngineIdentity.changeNote(from: same, to: .unknown))
    }

    func testTheSameRevisionSyncedAgainIsStillAChange() throws {
        // `engine.py sync` rewrote the tree: the files under a running build were swapped even if the pin is the same.
        let a = EngineIdentity.stamp("nx2apple-engine 1\npin f25fa9562ee96d06f1e6412dbb91aab2b7035ec1\nkey aaa\nhead 111\n")
        let b = EngineIdentity.stamp("nx2apple-engine 1\npin f25fa9562ee96d06f1e6412dbb91aab2b7035ec1\nkey aaa\nhead 222\n")
        let note = try XCTUnwrap(EngineIdentity.changeNote(from: a, to: b))
        XCTAssertTrue(note.contains("while it ran"), note)
    }
}
