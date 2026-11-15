import Foundation
import NXPocketKit

/// What the server may ask the launcher about builds, and the one thing it may ask it to do: queue the build of a game whose
/// dump is in the player's own folder. The server never names a path, a flag or a setting: a title ID is all that comes from the
/// phone, and it is looked up in what the launcher already knows.
public protocol BuildPort: Sendable {
    /// Whether the player allowed paired iPhones to start builds (off by default: a build is an hour of the Mac and gigabytes of disk).
    var allowsBuilds: Bool { get }
    /// The games of the dump folder, with where each one's build stands. The server drops the ones already built.
    func buildable() -> [RemoteBuildable]
    /// Queues the build. The launcher answers at once; how it goes shows in `buildable()`.
    func requestBuild(titleID: String) -> BuildAnswer
}

public enum BuildAnswer: Equatable, Sendable {
    case accepted
    /// Not a game of the dump folder, or already built.
    case notFound
    /// Already queued or building, or the phones have asked for as many as the launcher takes at once.
    case busy
}
