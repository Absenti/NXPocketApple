import Foundation
import NXPocketKit

/// Runs a tool and streams its output a line at a time, so a build that lasts twenty minutes shows where it is
/// without holding everything in memory.
///
/// Every line reaches `onLine`, in order, before `onExit` is called and before `waitUntilExit` returns: the output is
/// read to its end first. The process exiting is not that end, since bytes can still sit in the pipe; stopping at the
/// exit lost the engine's last lines, its `[RED]` reason and its `game files:` line among them.
public final class ProcessRunner: @unchecked Sendable {
    public struct Result: Sendable {
        public var status: Int32
        public var lines: [String]
        public var isCancelled: Bool
    }

    /// How many of the last lines the result keeps: a build prints far more, and each one went to `onLine` already.
    static let keptLines = 20_000
    /// How long the output is still waited for once the process has exited. A child it started and left running (a
    /// .NET build server) can hold the pipe open for good, and then the end of the output never comes.
    static let drainLimit: TimeInterval = 3

    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSCondition()
    private var tail = Data()
    private var kept = LineRing(capacity: keptLines)
    private var cancelled = false
    private var outputFinished = false
    private var exitDelivered = false

    public var onLine: ((String) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public init(executable: URL, arguments: [String], currentDirectory: URL? = nil,
                environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    public func start() throws {
        // FileHandle calls this on one queue, one call at a time, so lines come out in the order they were written.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.finishOutput() } else { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.global(qos: .userInitiated).async {
                guard let self else { return }
                self.waitForOutput()
                self.deliverExit(status)
            }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw NXPocketError(.engineFailed,
                                "\(process.executableURL?.lastPathComponent ?? "the tool") could not be started: \(error.localizedDescription)")
        }
    }

    /// Waits for the process and the end of its output.
    @discardableResult
    public func waitUntilExit() -> Result {
        process.waitUntilExit()
        waitForOutput()
        lock.lock()
        let result = Result(status: process.terminationStatus, lines: kept.lines, isCancelled: cancelled)
        lock.unlock()
        return result
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }

    private func consume(_ data: Data) {
        lock.lock()
        // Past the end (the wait gave up on a pipe held open): late bytes would reach onLine after onExit.
        guard !outputFinished else { lock.unlock(); return }
        tail.append(data)
        var output: [String] = []
        while let index = tail.firstIndex(of: 0x0A) {
            output.append(String(decoding: tail[tail.startIndex..<index], as: UTF8.self))
            tail.removeSubrange(tail.startIndex...index)
        }
        for line in output { kept.append(line) }
        lock.unlock()
        for line in output { onLine?(line) }
    }

    /// The end of the output: the last line without its newline goes out, then whoever waits is let through.
    private func finishOutput() {
        lock.lock()
        guard !outputFinished else { lock.unlock(); return }
        outputFinished = true
        let rest = tail
        tail.removeAll()
        if !rest.isEmpty { kept.append(String(decoding: rest, as: UTF8.self)) }
        lock.unlock()
        pipe.fileHandleForReading.readabilityHandler = nil
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
        lock.lock()
        lock.broadcast()
        lock.unlock()
    }

    private func waitForOutput() {
        let deadline = Date().addingTimeInterval(Self.drainLimit)
        lock.lock()
        while !outputFinished && lock.wait(until: deadline) {}
        let finished = outputFinished
        lock.unlock()
        if !finished { finishOutput() }
    }

    private func deliverExit(_ status: Int32) {
        lock.lock()
        let first = !exitDelivered
        exitDelivered = true
        lock.unlock()
        if first { onExit?(status) }
    }

    /// A short command whose whole output is wanted at once.
    public static func capture(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil,
                               timeout: TimeInterval = 30) throws -> Result {
        let runner = ProcessRunner(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        try runner.start()
        let deadline = Date().addingTimeInterval(timeout)
        while runner.isRunning, Date() < deadline { usleep(20_000) }
        if runner.isRunning {
            runner.cancel()
            throw NXPocketError(.engineFailed, "\(executable.lastPathComponent) did not answer within \(Int(timeout))s")
        }
        return runner.waitUntilExit()
    }
}

/// The last `capacity` lines, in order, without moving the others each time one is dropped: the result used to keep
/// its lines in an array whose first element was removed at every line past the limit.
struct LineRing {
    let capacity: Int
    private var storage: [String] = []
    private var start = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    mutating func append(_ line: String) {
        if storage.count < capacity {
            storage.append(line)
        } else {
            storage[start] = line
            start = (start + 1) % capacity
        }
    }

    var lines: [String] { Array(storage[start...] + storage[..<start]) }
}
