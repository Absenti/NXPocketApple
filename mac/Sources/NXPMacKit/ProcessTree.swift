import Darwin
import Foundation

/// A process and everything it started, for pausing a build as a whole.
///
/// The engine is a Python process that starts the others itself: Xcode for the game framework, the Metal compiler for
/// each of thousands of shaders, a pool of workers. Stopping only the Python process leaves them running, and a "paused"
/// build would go on compiling for minutes. They are not in a process group of their own (`Process` puts a child in the
/// launcher's), so the tree is walked.
public enum ProcessTree {
    /// Ids that are never part of a build's tree. 0 is the kernel: its "children" are every process on the Mac, and
    /// `kill(0, …)` is a signal to the caller's own process group. 1 is launchd. A process that has already exited
    /// reports id 0 through `ProcessRunner.processIdentifier`, so this is not a theoretical case: asking for the tree of
    /// such a runner returned all 1,000 processes of the machine.
    static func isUsable(_ pid: pid_t) -> Bool { pid > 1 }

    /// The direct children of `pid`.
    public static func children(of pid: pid_t) -> [pid_t] {
        guard isUsable(pid) else { return [] }
        var capacity = 64
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listchildpids(pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size)))
            guard count > 0 else { return [] }
            if count < capacity { return Array(buffer.prefix(count)).filter { $0 > 0 } }
            capacity *= 2
        }
    }

    /// `pid` and every process below it, parents first.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        guard isUsable(pid) else { return [] }
        var found: [pid_t] = []
        var seen = Set<pid_t>([pid])
        var work = [pid]
        while let next = work.popLast() {
            found.append(next)
            for child in children(of: next) where seen.insert(child).inserted { work.append(child) }
        }
        return found
    }

    /// Stops `pid` and everything below it, and returns what was stopped.
    ///
    /// A process is stopped before its children are listed, so it cannot start another meanwhile; one that was started
    /// just before it was stopped shows up in the next pass. Passes go on until one finds nobody new.
    @discardableResult
    public static func stop(rootedAt pid: pid_t, passes: Int = 6) -> [pid_t] {
        guard isUsable(pid) else { return [] }
        var stopped: [pid_t] = []
        var known = Set<pid_t>()
        for _ in 0..<passes {
            var foundNew = false
            var work = [pid]
            var visited = Set<pid_t>()
            while let next = work.popLast() {
                guard visited.insert(next).inserted else { continue }
                if known.insert(next).inserted {
                    if kill(next, SIGSTOP) == 0 {
                        stopped.append(next)
                        foundNew = true
                    }
                }
                work += children(of: next)
            }
            if !foundNew { break }
        }
        return stopped
    }

    /// A process told apart from another that reuses its id later: its id and the moment it started.
    public struct Member: Hashable, Sendable {
        public var pid: pid_t
        public var started: UInt64
    }

    /// When `pid` started, in microseconds since 1970; nil when there is no such process.
    public static func startTime(of pid: pid_t) -> UInt64? {
        guard isUsable(pid) else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// `pid` and everything below it, each with its start time.
    public static func members(of pid: pid_t) -> [Member] {
        descendants(of: pid).compactMap { child in startTime(of: child).map { Member(pid: child, started: $0) } }
    }

    /// Whether the very process is still there: an id that was reused by another process is not.
    public static func isAlive(_ member: Member) -> Bool {
        startTime(of: member.pid) == member.started
    }

    /// Sends `signal` to those of `members` that are still themselves, never to a process that took over an id.
    public static func send(_ signal: Int32, to members: [Member]) {
        for member in members where isUsable(member.pid) && isAlive(member) { kill(member.pid, signal) }
    }

    /// Lets the processes `stop` stopped run again. One that has gone since is skipped by the system.
    public static func resume(_ pids: [pid_t]) {
        // Children first: nothing wakes up before what it waits on.
        for pid in pids.reversed() where isUsable(pid) { kill(pid, SIGCONT) }
    }
}
