import Foundation

/// Where games come from: the Mac's library over HTTPS, a server reached over FTP. The downloader asks a source only
/// for names and bytes; what to ask for comes from the package's own `package.json`, and what comes back is checked
/// against it, so a source that lies can refuse to deliver but cannot make the phone write somewhere it did not plan.
public protocol PackageSource: Sendable {
    /// A stable id for the journal: two sources never share one, and the same source always has the same.
    var sourceID: String { get }

    func games() async throws -> [RemoteGame]

    /// The files a package holds and the revision they belong to.
    func listing(titleID: String) async throws -> RemotePackageListing

    /// One file from `offset` on. `revision` ties the request to the build the plan was made from; a source that has
    /// moved on throws `PackageSourceError.changed`.
    func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody

    /// The icon, at most `SharingLimits.iconBytes`, or nil when there is none.
    func icon(titleID: String) async throws -> Data?
}

/// The bytes of one file, from `offset`. A consumer that stops reading (or is cancelled) ends the stream, and the source
/// closes the connection.
public struct RemoteBody: Sendable {
    /// Where the first byte of `chunks` sits in the file. It must equal the offset asked for.
    public let offset: UInt64
    /// How many bytes the source says are coming, when it knows. A body longer than the plan allows is refused anyway.
    public let length: UInt64?
    public let chunks: AsyncThrowingStream<Data, Error>

    public init(offset: UInt64, length: UInt64?, chunks: AsyncThrowingStream<Data, Error>) {
        self.offset = offset
        self.length = length
        self.chunks = chunks
    }
}

public enum PackageSourceError: Error, Equatable, Sendable {
    /// The package was rebuilt (or renamed) since the plan was made: the plan is no longer the source's.
    case changed
    /// The source does not have this game, file, or folder.
    case notFound
    /// The token or password was refused, or the source needs pairing again.
    case unauthorized
    /// The source's key is not the one this phone pinned.
    case untrusted(fingerprint: String)
    /// The source says it is rebuilding this game.
    case busy
    /// The source does not take saves: the Mac has that switched off.
    case notAccepting
    /// The source has no room for what was sent, or the file is over what it takes.
    case noRoom
    case unreachable(String)
    /// The source answered with something that is not part of the protocol.
    case malformed(String)
}
