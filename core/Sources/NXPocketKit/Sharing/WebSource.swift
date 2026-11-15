import Foundation

/// Games on a static web server the player owns: an `index.json`, and for each game a folder of its files with a `files.json` beside
/// them, all made by the launcher's *Export for the web* and put anywhere that serves files over https (a NAS behind a reverse proxy, a
/// Nextcloud, an object store). There is no FTP and no program on the server: it only has to answer GET and `Range`.
///
/// ```
/// <base>/index.json                       {"games":[…]}               what `RemoteListing` is
/// <base>/<TITLE>.nxgame/files.json        {"revision","files":[…]}    what `RemotePackageListing` is
/// <base>/<TITLE>.nxgame/<path>            each file of the package
/// <base>/icons/<TITLE>.png                the icon, a PNG that passes `PNGHeader`
/// ```
///
/// Everything here is as untrusted as an SFTP server's: the plan comes from the game's own `package.json`, the lists are bounded and
/// compared with it, and every file is checked as it arrives. The address is the secret (a path only the player knows, or a query), and
/// an access token may be added: it is sent as a bearer token, only to this address. The certificate is judged by the system, and no
/// redirect is followed, so the token cannot be sent anywhere else.
public final class WebSource: BackgroundReadable, @unchecked Sendable {
    public let baseURL: URL
    private let token: String?
    private let session: HTTPSession

    public var sourceID: String { Self.sourceID(for: baseURL) }

    public static func sourceID(for url: URL) -> String { "web-" + FileDigest.sha256(of: Data(url.absoluteString.utf8)).prefix(16) }

    /// Nil unless the address is an https one with a host: a plain http link would send the token and the games in the clear.
    public static func validated(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    public convenience init(baseURL: URL, token: String? = nil, idleTimeout: TimeInterval = SharingLimits.idleTimeout) {
        self.init(baseURL: baseURL, token: token, session: HTTPSession(trust: .system, idleTimeout: idleTimeout))
    }

    init(baseURL: URL, token: String?, session: HTTPSession) {
        self.baseURL = baseURL
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.session = session
    }

    deinit { session.invalidate() }

    // MARK: PackageSource

    public func games() async throws -> [RemoteGame] {
        try RemoteListing.decode(try await bounded(["index.json"], limit: SharingLimits.metadataBytes))
    }

    public func listing(titleID: String) async throws -> RemotePackageListing {
        try RemotePackageListing.decode(try await bounded(["\(titleID.uppercased()).nxgame", "files.json"], limit: SharingLimits.metadataBytes))
    }

    public func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody {
        guard SafePath.isSafeRelative(path) else { throw PackageSourceError.malformed("\"\(path)\" is not a path in a package") }
        var request = try makeRequest(["\(titleID.uppercased()).nxgame"] + path.split(separator: "/").map(String.init))
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let transfer = session.start(request)
        let response = try await transfer.awaitHead()
        try Self.check(response)
        guard let length = transfer.declaredLength, length >= 0 else {
            transfer.cancel()
            throw PackageSourceError.malformed("the answer does not say how long it is")
        }
        if offset > 0 {
            guard response.statusCode == 206, let range = PinnedHTTPSSource.contentRange(response), range.first == offset,
                  UInt64(length) == range.total - offset, range.last + 1 == range.total else {
                transfer.cancel()
                // A server that ignores Range sends the whole file with a 200: a resume is not possible from it.
                throw PackageSourceError.malformed("the server does not resume a download (no Range support)")
            }
        } else if response.statusCode != 200 {
            transfer.cancel()
            throw PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
        return RemoteBody(offset: offset, length: UInt64(length), chunks: transfer.stream())
    }

    public func segmentBase(titleID: String, revision: String, path: String) throws -> (request: URLRequest, trust: SegmentTrust) {
        guard SafePath.isSafeRelative(path) else { throw PackageSourceError.malformed("\"\(path)\" is not a path in a package") }
        return (try makeRequest(["\(titleID.uppercased()).nxgame"] + path.split(separator: "/").map(String.init)), .system)
    }

    public func icon(titleID: String) async throws -> Data? {
        do {
            let data = try await bounded(["icons", "\(titleID.uppercased()).png"], limit: SharingLimits.iconBytes)
            return PNGHeader.isAcceptableIcon(data) ? data : nil
        } catch PackageSourceError.notFound {
            return nil
        }
    }

    // MARK: requests

    /// The address with the path's pieces added, each percent-encoded on its own so a name can never add a segment, a query or a fragment.
    func makeRequest(_ segments: [String]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw PackageSourceError.malformed("\(baseURL.absoluteString) is not an address")
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }.joined(separator: "/")
        guard let url = components.url else { throw PackageSourceError.malformed("\(baseURL.absoluteString) is not an address") }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func bounded(_ segments: [String], limit: Int) async throws -> Data {
        let transfer = session.start(try makeRequest(segments))
        let response = try await transfer.awaitHead()
        try Self.check(response)
        if let length = transfer.declaredLength, length > Int64(limit) {
            transfer.cancel()
            throw PackageSourceError.malformed("the answer is larger than \(limit) bytes")
        }
        return try await PinnedHTTPSSource.collect(transfer, limit: limit)
    }

    static func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200, 206: return
        case 401, 403: throw PackageSourceError.unauthorized
        case 404, 410: throw PackageSourceError.notFound
        case 301, 302, 303, 307, 308: throw PackageSourceError.malformed("the link redirects: use the address it redirects to")
        case 429, 503: throw PackageSourceError.unreachable("the server is busy, try again in a moment")
        default: throw PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
    }
}
