import Foundation

/// A game the Mac has the dump of and has not built yet: what the phone shows as a tile "to build", and where its build stands.
public struct RemoteBuildable: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case idle, queued, building, failed }

    public var titleID: String
    public var name: String
    public var state: State
    /// 0 to 1 while it builds.
    public var progress: Double
    /// Why the last build failed, in the Mac's words, bounded.
    public var detail: String
    public var id: String { titleID }

    enum CodingKeys: String, CodingKey {
        case name, state, progress, detail
        case titleID = "title_id"
    }

    public init(titleID: String, name: String, state: State, progress: Double = 0, detail: String = "") {
        self.titleID = titleID
        self.name = name
        self.state = state
        self.progress = progress
        self.detail = detail
    }

    /// Decodes and bounds the answer of `GET /v1/buildable`: a game that is not a game is dropped, free text is cut and stripped.
    public static func decode(_ data: Data) throws -> [RemoteBuildable] { try decodeListing(data).games }

    /// The same, with whether the Mac lets phones ask for builds. A Mac that does not say (an older launcher) is taken as allowing.
    public static func decodeListing(_ data: Data) throws -> (games: [RemoteBuildable], allowed: Bool) {
        guard data.count <= SharingLimits.metadataBytes else { throw NXPocketError(.packageDamaged, "the list of games to build is too large") }
        struct Listing: Decodable { var games: [RemoteBuildable]; var allowed: Bool? }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data), listing.games.count <= SharingLimits.maxGames else {
            throw NXPocketError(.packageDamaged, "the list of games to build could not be read")
        }
        var seen = Set<String>()
        let games = listing.games.compactMap { game -> RemoteBuildable? in
            guard TitleID.isGame(game.titleID), let id = TitleID(game.titleID), seen.insert(id.description).inserted else { return nil }
            var clean = game
            clean.titleID = id.description
            clean.name = RemoteListing.text(game.name, limit: 120)
            clean.detail = RemoteListing.text(game.detail, limit: 160)
            clean.progress = game.progress.isFinite ? min(max(game.progress, 0), 1) : 0
            return clean
        }
        return (games, listing.allowed ?? true)
    }
}

/// A source that can be asked to build a game it has the dump of: the Mac.
public protocol BuildRequesting: Sendable {
    func buildable() async throws -> [RemoteBuildable]
    /// The games, and whether the player allowed phones to ask for builds on the Mac.
    func buildableListing() async throws -> (games: [RemoteBuildable], allowed: Bool)
    /// Asks for a build. Throws `PackageSourceError.notAccepting` when the player has not allowed it on the Mac.
    func requestBuild(titleID: String) async throws
}

extension PinnedHTTPSSource: BuildRequesting {
    public func buildable() async throws -> [RemoteBuildable] { try await buildableListing().games }

    public func buildableListing() async throws -> (games: [RemoteBuildable], allowed: Bool) {
        try RemoteBuildable.decodeListing(try await boundedGet("/v1/buildable"))
    }

    public func requestBuild(titleID: String) async throws {
        guard TitleID.isGame(titleID) else { throw NXPocketError(.packageDamaged, "\"\(titleID)\" is not a game's title ID") }
        var request = try makeBuildRequest(titleID: titleID.uppercased())
        request.httpMethod = "POST"
        let transfer = session.start(request)
        let response = try await transfer.awaitHead()
        _ = try? await Self.collect(transfer, limit: 4096)
        switch response.statusCode {
        case 200: return
        case 401: throw PackageSourceError.unauthorized
        case 403: throw PackageSourceError.notAccepting
        case 404: throw PackageSourceError.notFound
        case 423, 429, 503: throw PackageSourceError.busy
        default: throw PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
    }
}
