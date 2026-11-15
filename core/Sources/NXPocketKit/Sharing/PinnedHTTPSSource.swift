import CryptoKit
import Foundation

/// What a pairing leaves on the phone: the Mac's key (as its pin), the token the Mac issued, and the Mac's name.
public struct PairedMac: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var pin: String
    public var token: String
    public var name: String

    public init(host: String, port: Int, pin: String, token: String, name: String) {
        self.host = host
        self.port = port
        self.pin = pin
        self.token = token
        self.name = name
    }
}

public enum PairingError: Error, Equatable, Sendable {
    /// What was typed is not a code (wrong length or characters).
    case malformedCode
    /// The Mac did not accept the code: wrong, used, or older than its two minutes.
    case refused
    /// Too many attempts: the Mac says to wait.
    case rateLimited
    /// The Mac's answer did not prove it knows the code: whoever answered is not the Mac the code came from.
    case wrongMac
}

/// The Mac's library over HTTPS, reached on the local network: `docs/SHARING.md` §2 to §4.
///
/// The server is known by the hash of its public key (`pin`), fixed when the phone paired, and never by a certificate
/// chain: its certificate is self-signed and its names and dates do not matter. Every request carries the token the Mac
/// issued, and every failure to authenticate is the same `401`, so a wrong token and a revoked one look alike.
public final class PinnedHTTPSSource: BackgroundReadable, SaveDestination, SaveSource, @unchecked Sendable {
    public let host: String
    public let port: Int
    public let pin: String
    private let token: String
    let session: HTTPSession

    public var sourceID: String { Self.sourceID(pin: pin) }

    /// A Mac is identified by its key, not by its address: the address changes, the key is what was paired with.
    public static func sourceID(pin: String) -> String { "mac-" + pin.prefix(16) }

    public convenience init(_ mac: PairedMac) {
        self.init(host: mac.host, port: mac.port, pin: mac.pin, token: mac.token)
    }

    public init(host: String, port: Int, pin: String, token: String, idleTimeout: TimeInterval = SharingLimits.idleTimeout) {
        self.host = host
        self.port = port
        self.pin = pin
        self.token = token
        self.session = HTTPSession(trust: .pinned(pin), idleTimeout: idleTimeout)
    }

    deinit { session.invalidate() }

    // MARK: PackageSource

    public func games() async throws -> [RemoteGame] {
        try RemoteListing.decode(try await bounded("/v1/games", limit: SharingLimits.metadataBytes))
    }

    public func listing(titleID: String) async throws -> RemotePackageListing {
        try RemotePackageListing.decode(try await bounded("/v1/games/\(titleID)", limit: SharingLimits.metadataBytes))
    }

    public func read(titleID: String, revision: String, path: String, offset: UInt64) async throws -> RemoteBody {
        let segments = ["v1", "games", titleID, revision, "files"] + path.split(separator: "/").map(String.init)
        var request = try makeRequest(segments: segments)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let transfer = session.start(request)
        let response = try await transfer.awaitHead()
        try Self.check(response)
        guard let length = transfer.declaredLength, length >= 0 else {
            transfer.cancel()
            throw PackageSourceError.malformed("the answer does not say how long it is")
        }
        if offset > 0 {
            guard response.statusCode == 206, let range = Self.contentRange(response), range.first == offset,
                  UInt64(length) == range.total - offset, range.last + 1 == range.total else {
                transfer.cancel()
                throw PackageSourceError.malformed("the answer is not the range that was asked for")
            }
        } else if response.statusCode != 200 {
            transfer.cancel()
            throw PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
        return RemoteBody(offset: offset, length: UInt64(length), chunks: transfer.stream())
    }

    public func segmentBase(titleID: String, revision: String, path: String) throws -> (request: URLRequest, trust: SegmentTrust) {
        let segments = ["v1", "games", titleID, revision, "files"] + path.split(separator: "/").map(String.init)
        return (try makeRequest(segments: segments), .pinned(pin))
    }

    public func icon(titleID: String) async throws -> Data? {
        do {
            let data = try await bounded("/v1/games/\(titleID)/icon", limit: SharingLimits.iconBytes)
            return PNGHeader.isAcceptableIcon(data) ? data : nil
        } catch PackageSourceError.notFound {
            return nil
        }
    }

    // MARK: pairing

    /// First contact: which key does this address present, and what does it call itself. Nothing is trusted yet; the
    /// pairing that follows is what ties the key to the Mac the player means.
    public static func hello(host: String, port: Int) async throws -> (pin: String, name: String) {
        let session = HTTPSession(trust: .observe)
        defer { session.invalidate() }
        let body = try await Self.bounded(session, host: host, port: port, path: "/v1/hello", token: nil, limit: 4096)
        guard let pin = session.observedPin,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], json["protocol"] as? Int == 1 else {
            throw PackageSourceError.malformed("this is not a Mac running NXPocketApple")
        }
        return (pin, (json["name"] as? String).map { RemoteListing.text($0, limit: 64) } ?? host)
    }

    /// Pairs with the Mac at `host:port` using the code on its screen. The code never leaves the phone: the Mac and the
    /// phone each prove they know it, bound to the key the phone saw (`PairingProof`).
    public static func pair(host: String, port: Int, code: String, deviceName: String) async throws -> PairedMac {
        guard PairingProof.normalise(code) != nil else { throw PairingError.malformedCode }
        let (pin, macName) = try await hello(host: host, port: port)
        guard let key = PairingProof.key(code: code, pin: pin) else { throw PairingError.malformedCode }
        return try await prove(host: host, port: port, pin: pin, macName: macName, key: key, deviceName: deviceName)
    }

    /// Pairs from a scanned QR code. The link names the Mac's key: a server that presents another one is not the Mac
    /// whose screen showed the code, and nothing is sent to it.
    public static func pair(link: PairLink, deviceName: String) async throws -> PairedMac {
        let (pin, macName) = try await hello(host: link.address, port: link.port)
        guard pin == link.pin, let key = PairingProof.key(secret: link.secret, pin: pin) else { throw PairingError.wrongMac }
        return try await prove(host: link.address, port: link.port, pin: pin, macName: macName, key: key, deviceName: deviceName)
    }

    private static func prove(host: String, port: Int, pin: String, macName: String, key: SymmetricKey, deviceName: String) async throws -> PairedMac {
        let name = RemoteListing.text(deviceName, limit: PairingProof.maxNameLength)
        let nonce = PairingProof.nonce()
        let session = HTTPSession(trust: .pinned(pin))
        defer { session.invalidate() }
        let (status, body) = try await post(session, host: host, port: port, path: "pair", [
            "name": name, "nonce": nonce,
            "proof": PairingProof.clientProof(key: key, pin: pin, nonce: nonce, name: name)
        ])
        try checkPairing(status)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = json["token"] as? String, token.count == 64, FileDigest.isSHA256(token),
              let proof = json["proof"] as? String,
              PairingProof.isValid(proof, key: key, role: "s", pin: pin, nonce: nonce, subject: token) else {
            throw PairingError.wrongMac
        }
        return PairedMac(host: host, port: port, pin: pin, token: token,
                         name: (json["name"] as? String).map { RemoteListing.text($0, limit: 64) } ?? macName)
    }

    static func post(_ session: HTTPSession, host: String, port: Int, path: String, _ object: [String: Any]) async throws -> (Int, Data) {
        var request = try makeRequest(host: host, port: port, segments: ["v1"] + path.split(separator: "/").map(String.init), token: nil)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let transfer = session.start(request)
        let response = try await transfer.awaitHead()
        return (response.statusCode, try await collect(transfer, limit: 4096))
    }

    static func checkPairing(_ status: Int) throws {
        switch status {
        case 200: return
        case 401, 403: throw PairingError.refused
        case 423: throw PackageSourceError.busy
        case 429: throw PairingError.rateLimited
        default: throw PackageSourceError.malformed("unexpected answer \(status)")
        }
    }

    // MARK: saves

    /// `PUT /v1/saves/<title ID>`: the copy goes up as one body, and the Mac answers once it has the whole of it on disk.
    @discardableResult
    public func store(saves archive: URL, titleID: String) async throws -> String {
        _ = try SaveUpload.checked(archive, titleID: titleID)
        var request = try makeRequest(segments: ["v1", "saves", titleID.uppercased()])
        request.httpMethod = "PUT"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        let transfer = session.upload(request, file: archive)
        let response = try await transfer.awaitHead()
        let answer = (try? await Self.collect(transfer, limit: 4096)) ?? Data()
        switch response.statusCode {
        case 200:
            return ((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any])?["stored"] as? String ?? ""
        case 401: throw PackageSourceError.unauthorized
        case 403: throw PackageSourceError.notAccepting
        case 413, 507: throw PackageSourceError.noRoom
        case 429, 503: throw PackageSourceError.unreachable("the Mac is busy, try again in a moment")
        default: throw PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
    }

    // MARK: copies of saves, back

    public func saveCopies(titleID: String) async throws -> [RemoteSaveCopy] {
        guard TitleID.isGame(titleID) else { throw NXPocketError(.packageDamaged, "\"\(titleID)\" is not a game's title ID") }
        let transfer = session.start(try makeRequest(segments: ["v1", "saves", titleID.uppercased()]))
        let response = try await transfer.awaitHead()
        switch response.statusCode {
        case 200: return try RemoteSaveCopy.decode(try await Self.collect(transfer, limit: SharingLimits.metadataBytes))
        case 401: throw PackageSourceError.unauthorized
        case 403: throw PackageSourceError.notAccepting
        default: throw PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
    }

    public func fetchSaveCopy(titleID: String, name: String, to destination: URL) async throws {
        guard TitleID.isGame(titleID), SaveUpload.isCopyName(name) else { throw NXPocketError(.packageDamaged, "that is not a copy of saves") }
        let request = try makeRequest(segments: ["v1", "saves", titleID.uppercased(), name])
        let transfer = session.start(request)
        let response = try await transfer.awaitHead()
        switch response.statusCode {
        case 200: break
        case 401: throw PackageSourceError.unauthorized
        case 403: throw PackageSourceError.notAccepting
        case 404: throw PackageSourceError.notFound
        default: throw PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
        if let length = transfer.declaredLength, length > SaveUpload.maxBytes { transfer.cancel(); throw PackageSourceError.noRoom }
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw NXPocketError(.transferFailed, "a file for the copy could not be made")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var written: Int64 = 0
        do {
            while let chunk = try await transfer.next() {
                written += Int64(chunk.count)
                guard written <= SaveUpload.maxBytes else { throw PackageSourceError.noRoom }
                try handle.write(contentsOf: chunk)
            }
            guard SaveUpload.isZip(destination) else { throw PackageSourceError.malformed("what came is not a copy of saves") }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: requests

    func boundedGet(_ path: String) async throws -> Data { try await bounded(path, limit: SharingLimits.metadataBytes) }

    func makeBuildRequest(titleID: String) throws -> URLRequest { try makeRequest(segments: ["v1", "build", titleID]) }

    private func bounded(_ path: String, limit: Int) async throws -> Data {
        try await Self.bounded(session, host: host, port: port, path: path, token: token, limit: limit)
    }

    private static func bounded(_ session: HTTPSession, host: String, port: Int, path: String, token: String?, limit: Int) async throws -> Data {
        let request = try makeRequest(host: host, port: port, segments: path.split(separator: "/").map(String.init), token: token)
        let transfer = session.start(request)
        let response = try await transfer.awaitHead()
        try check(response)
        if let length = transfer.declaredLength, length > Int64(limit) {
            transfer.cancel()
            throw PackageSourceError.malformed("the answer is larger than \(limit) bytes")
        }
        return try await collect(transfer, limit: limit)
    }

    static func collect(_ transfer: HTTPTransfer, limit: Int) async throws -> Data {
        var data = Data()
        while let chunk = try await transfer.next() {
            data.append(chunk)
            guard data.count <= limit else {
                transfer.cancel()
                throw PackageSourceError.malformed("the answer is larger than \(limit) bytes")
            }
        }
        return data
    }

    private func makeRequest(segments: [String]) throws -> URLRequest {
        try Self.makeRequest(host: host, port: port, segments: segments, token: token)
    }

    /// Each path segment is percent-encoded on its own, down to the unreserved characters, so a name can never add a
    /// segment, a query or a fragment to the path.
    static func makeRequest(host: String, port: Int, segments: [String], token: String?) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedPath = "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }.joined(separator: "/")
        guard let url = components.url else { throw PackageSourceError.malformed("\(host) is not an address") }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200, 206: return
        case 401, 403: throw PackageSourceError.unauthorized
        case 404: throw PackageSourceError.notFound
        case 409: throw PackageSourceError.changed
        case 423: throw PackageSourceError.busy
        case 429, 503: throw PackageSourceError.unreachable("the Mac is busy, try again in a moment")
        default: throw PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
    }

    /// `Content-Range: bytes first-last/total`.
    static func contentRange(_ response: HTTPURLResponse) -> (first: UInt64, last: UInt64, total: UInt64)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 3, let first = UInt64(parts[0]), let last = UInt64(parts[1]), let total = UInt64(parts[2]),
              first <= last, last < total else { return nil }
        return (first, last, total)
    }
}

/// An icon is a PNG of at most `SharingLimits.iconBytes` and `iconPixels` a side. The header is read, not the image
/// decoded: what a source sends is not run through an image decoder before it has passed this.
public enum PNGHeader {
    public static func isAcceptableIcon(_ data: Data) -> Bool {
        guard data.count >= 33, data.count <= SharingLimits.iconBytes,
              Array(data[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
              Array(data[12..<16]) == Array("IHDR".utf8) else { return false }
        func be(_ range: Range<Int>) -> Int { data[range].reduce(0) { $0 << 8 | Int($1) } }
        let width = be(16..<20), height = be(20..<24)
        return (1...SharingLimits.iconPixels).contains(width) && (1...SharingLimits.iconPixels).contains(height)
    }
}
