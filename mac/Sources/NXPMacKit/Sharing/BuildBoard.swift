import Foundation
import NXPocketKit

/// What the server reads of the launcher's builds, from its own threads: the dump folder's games and where each build stands, and
/// whether the player allowed iPhones to ask. The launcher keeps it current; a request goes back to the main actor through `ask`.
public final class BuildBoard: BuildPort, @unchecked Sendable {
    /// At most this many builds queued or running at once may come from phones: the launcher's cores are one engine's.
    public static let phoneLimit = 3

    private let lock = NSLock()
    private var games: [RemoteBuildable] = []
    private var allowed = false
    public var ask: @Sendable (String) -> Void = { _ in }

    public init() {}

    public func set(_ games: [RemoteBuildable], allowed: Bool) { lock.withLock { self.games = games; self.allowed = allowed } }
    public var allowsBuilds: Bool { lock.withLock { allowed } }
    public func buildable() -> [RemoteBuildable] { lock.withLock { games } }

    public func requestBuild(titleID: String) -> BuildAnswer {
        lock.withLock { () -> BuildAnswer in
            guard allowed, let index = games.firstIndex(where: { $0.titleID == titleID }) else { return .notFound }
            guard games[index].state == .idle || games[index].state == .failed else { return .busy }
            guard games.filter({ $0.state == .queued || $0.state == .building }).count < Self.phoneLimit else { return .busy }
            // Shown as queued at once: a second request before the launcher answers is refused as busy.
            games[index].state = .queued
            ask(titleID)
            return .accepted
        }
    }
}
