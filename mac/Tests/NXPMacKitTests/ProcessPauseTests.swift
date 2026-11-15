import Darwin
import XCTest
@testable import NXPMacKit
@testable import NXPMacModel

/// Pausing a build means stopping a whole tree: the engine starts Xcode, the Metal compiler and a pool of workers.
/// These run real processes (a shell with two long-lived children and a loop that prints), not a mock.
final class ProcessPauseTests: XCTestCase {
    private static let script = "sleep 60 & sleep 60 & i=0; while true; do echo tick $i; i=$((i+1)); sleep 0.05; done"

    private func state(_ pid: pid_t) -> String { ps("stat", pid) }

    private func ps(_ field: String, _ pid: pid_t) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "\(field)=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func started() throws -> (runner: ProcessRunner, lines: Lines, root: pid_t, sleepers: [pid_t]) {
        let lines = Lines()
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", Self.script])
        runner.onLine = { lines.add($0) }
        try runner.start()
        // The two sleepers are the children that stay: the loop's own short sleeps come and go, so they are picked by
        // their command, not by position (a short sleep that has exited by the time it is checked has no state to read).
        var sleepers: [pid_t] = []
        let deadline = Date().addingTimeInterval(5)
        var root: pid_t = 0
        while Date() < deadline {
            let all = ProcessTree.descendants(of: pidOf(runner))
            root = all.first ?? 0
            sleepers = all.dropFirst().filter { ps("command", $0) == "sleep 60" }
            if lines.count > 3, sleepers.count >= 2 { break }
            usleep(50_000)
        }
        XCTAssertGreaterThan(root, 0)
        addTeardownBlock {
            runner.cancel()
            for pid in ProcessTree.descendants(of: root) { kill(pid, SIGKILL) }
            for pid in sleepers { kill(pid, SIGKILL) }
        }
        return (runner, lines, root, sleepers)
    }

    /// `ProcessRunner` keeps its `Process` private; its pid is found through the one child tree we started.
    private func pidOf(_ runner: ProcessRunner) -> pid_t { runner.processIdentifier }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    }

    func testPausingStopsTheProcessAndEveryChildAndNothingIsPrintedMeanwhile() throws {
        let (runner, lines, root, sleepers) = try started()
        XCTAssertTrue(runner.pause())
        XCTAssertTrue(runner.isPaused)
        for pid in [root] + sleepers {
            XCTAssertTrue(state(pid).hasPrefix("T"), "process \(pid) is \(state(pid)), not stopped")
        }
        let before = lines.count
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(lines.count, before, "a paused build prints nothing")
        XCTAssertTrue(runner.isRunning, "paused is not dead")

        XCTAssertTrue(runner.resume())
        XCTAssertFalse(runner.isPaused)
        for pid in [root] + sleepers {
            XCTAssertFalse(state(pid).hasPrefix("T"), "process \(pid) is still stopped after the resume")
        }
        let resumeAt = Date()
        while lines.count <= before + 2, Date().timeIntervalSince(resumeAt) < 5 { usleep(50_000) }
        XCTAssertGreaterThan(lines.count, before + 2, "output goes on after the resume")
    }

    func testAPausedBuildCanBeCancelledAtOnce() throws {
        let (runner, _, root, sleepers) = try started()
        XCTAssertTrue(runner.pause())
        let cancelAt = Date()
        runner.cancel()
        let result = runner.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(cancelAt), 5, "SIGTERM does nothing to a stopped process: cancel wakes it first")
        XCTAssertTrue(result.isCancelled)
        XCTAssertFalse(runner.isPaused)
        // What it started must not be left stopped with nobody to wake it.
        for pid in sleepers where kill(pid, 0) == 0 {
            XCTAssertFalse(state(pid).hasPrefix("T"), "\(pid) was left stopped")
        }
        _ = root
    }

    func testPauseAndResumeAreIdempotentAndRefusedWhenThereIsNothingToPause() throws {
        let (runner, _, _, _) = try started()
        XCTAssertFalse(runner.resume(), "not paused")
        XCTAssertTrue(runner.pause())
        XCTAssertFalse(runner.pause(), "already paused")
        XCTAssertTrue(runner.resume())
        XCTAssertFalse(runner.resume())
        runner.cancel()
        runner.waitUntilExit()
        XCTAssertFalse(runner.pause(), "a build that is over cannot be paused")
    }

    func testTheTreeIsWalkedBelowTheFirstChildren() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sh -c 'sleep 30 & wait' & wait"]
        try process.run()
        addTeardownBlock {
            for pid in ProcessTree.descendants(of: process.processIdentifier) { kill(pid, SIGKILL) }
        }
        var tree: [pid_t] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            tree = ProcessTree.descendants(of: process.processIdentifier)
            if tree.count >= 3 { break }
            usleep(50_000)
        }
        XCTAssertGreaterThanOrEqual(tree.count, 3, "the shell, its child shell and the sleep below it")
        let stopped = ProcessTree.stop(rootedAt: process.processIdentifier)
        XCTAssertGreaterThanOrEqual(stopped.count, 3)
        XCTAssertTrue(stopped.allSatisfy { state($0).hasPrefix("T") })
        ProcessTree.resume(stopped)
        XCTAssertTrue(stopped.allSatisfy { !state($0).hasPrefix("T") })
    }
}

/// What the queue shows of a paused build.
final class PausedItemTests: XCTestCase {
    private func item(_ phase: QueueItem.Phase) -> QueueItem {
        var item = QueueItem(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe",
                             job: .build(BuildPlan(titleID: "0100152000022000", name: "Mario Kart 8 Deluxe", inputs: [], version: 0,
                                                   packageVersion: nil, dlcTitleIDs: [],
                                                   workFolder: URL(fileURLWithPath: "/tmp/x"), compressed: false), sendTo: nil))
        item.phase = phase
        return item
    }

    func testOnlyABuildUnderWayCanBePaused() {
        XCTAssertTrue(item(.building(stage: "3/9 · iOS shaders", stageFraction: 0.4, overall: 0.3, detail: "")).canPause)
        for phase: QueueItem.Phase in [.waiting, .packing(fraction: 0.5, detail: ""), .sending(fraction: 0.5, detail: ""),
                                       .needsAnswer("?"), .done("ok"), .failed("no"), .cancelled] {
            XCTAssertFalse(item(phase).canPause, "\(phase)")
        }
    }

    func testAPausedBuildSaysSoAndKeepsItsProgress() {
        var paused = item(.building(stage: "3/9 · iOS shaders", stageFraction: 0.4, overall: 0.3, detail: "4,000 of 10,000"))
        XCTAssertEqual(paused.status, "building · 3/9 · iOS shaders")
        let fraction = paused.fraction
        paused.isPaused = true
        XCTAssertEqual(paused.status, "paused · 3/9 · iOS shaders")
        XCTAssertEqual(paused.fraction, fraction, "the bar stays where it stopped")
        XCTAssertEqual(paused.detail?.text, "4,000 of 10,000")
        XCTAssertTrue(paused.phase.isActive, "a paused build is still the one under way: the queue waits for it")
    }
}
