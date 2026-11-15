import CryptoKit
import Foundation
import NXPocketKit

enum ShareBody {
    case none
    case data(Data)
    /// `length` bytes of the file from `offset`: the descriptor was opened and checked by `SharedLibrary`.
    case file(OpenedFile, offset: Int64, length: Int64)
}

struct ShareResponse {
    var status: Int
    var contentType: String = "application/json"
    var headers: [(String, String)] = []
    var body: ShareBody = .none
    var closeAfter = false
    /// A `HEAD` answer says how long the body would be.
    var headLength: Int64?
    /// The phone this answer is for, once its token checked out: a revocation cuts the connections that carry it.
    var deviceID: String?
    /// For the launcher's log.
    var note: String?

    static func json(_ status: Int, _ object: Any, close: Bool = false) -> ShareResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ShareResponse(status: status, body: .data(data), closeAfter: close)
    }

    static func encoded<T: Encodable>(_ value: T) -> ShareResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ShareResponse(status: 200, body: .data((try? encoder.encode(value)) ?? Data("{}".utf8)))
    }

    /// Every failure to authenticate says the same thing, whatever its cause: a wrong token, a revoked one and a missing
    /// one cannot be told apart from outside.
    static let unauthorized = ShareResponse(status: 401, body: .data(Data("{\"error\":\"unauthorized\"}".utf8)))
    static let notFound = ShareResponse(status: 404, body: .data(Data("{\"error\":\"not found\"}".utf8)))
    static func status(_ code: Int, close: Bool = false) -> ShareResponse {
        ShareResponse(status: code, body: .data(Data("{\"error\":\"\(code)\"}".utf8)), closeAfter: close)
    }
}

struct SaveCopyListing: Encodable {
    struct Entry: Encodable { var name: String; var size: Int64 }
    var copies: [Entry]
}

struct BuildableListing: Encodable {
    var games: [RemoteBuildable]
    /// False while the player has not allowed phones to ask for builds: the list is empty then, and the phone can say why.
    var allowed = true
}

/// What the answer to each request is: the whole API of `docs/SHARING.md` §4, with no socket in it, so every rule
/// is tested by handing it a request.
final class ShareRouter: @unchecked Sendable {
    let library: SharedLibrary
    let devices: PairedDevices
    let pairing: PairingSessions
    let limiter: RateLimiter
    let pin: String
    let name: String
    let inbox: SaveInbox?
    let builds: BuildPort?

    init(library: SharedLibrary, devices: PairedDevices, pairing: PairingSessions, limiter: RateLimiter, pin: String, name: String,
         inbox: SaveInbox? = nil, builds: BuildPort? = nil) {
        self.inbox = inbox
        self.builds = builds
        self.library = library
        self.devices = devices
        self.pairing = pairing
        self.limiter = limiter
        self.pin = pin
        self.name = name
    }

    func respond(to request: HTTPRequest, peer: String, now: Date = Date()) -> ShareResponse {
        let segments = request.segments
        guard segments.first == "v1", segments.count >= 2 else { return .notFound }

        // The two doors that need no token. Everything else does, and checks it before it looks at the path.
        if segments == ["v1", "hello"] {
            guard request.method == "GET" || request.method == "HEAD" else { return .status(405) }
            return .json(200, ["protocol": 1, "name": name])
        }
        if segments == ["v1", "pair"] {
            guard request.method == "POST" else { return .status(405) }
            return pair(request, peer: peer, now: now)
        }
        if segments.count == 3, segments[1] == "pair", ["request", "reveal", "confirm", "cancel"].contains(segments[2]) {
            guard request.method == "POST" else { return .status(405) }
            return compare(segments[2], request, peer: peer, now: now)
        }

        guard limiter.allows(peer, now: now) else { return ShareResponse.status(429, close: true) }
        // The one POST behind a token: asking for the build of a game (`POST /v1/build/<title ID>`, no body).
        let asksBuild = request.method == "POST" && segments.count == 3 && segments[1] == "build"
        guard request.method == "GET" || request.method == "HEAD" || asksBuild else { return .status(405) }
        guard let token = Self.bearer(request), let device = devices.authenticate(token, now: now) else {
            limiter.recordFailure(peer, now: now)
            var response = ShareResponse.unauthorized
            response.closeAfter = true
            return response
        }
        var response = route(segments, request: request)
        response.deviceID = device.id
        return response
    }

    // MARK: saves

    enum UploadDecision {
        case accept(SaveInbox.Upload, device: PairedDevice)
        /// An answer, and the connection closed after it: the body was not read, so the connection cannot carry another request.
        case refuse(ShareResponse)
    }

    /// `PUT /v1/saves/<title ID>`, decided from its head alone: the token is checked, and so is everything about the copy that
    /// does not need its bytes, before the first of them is read. The one place a phone writes anything on this Mac.
    func authorizeUpload(_ request: HTTPRequest, length: Int64, peer: String, now: Date = Date()) -> UploadDecision {
        guard limiter.allows(peer, now: now) else { return .refuse(ShareResponse.status(429, close: true)) }
        guard request.method == "PUT", request.segments.count == 3, request.segments[..<2] == ["v1", "saves"] else {
            return .refuse(.status(405, close: true))
        }
        guard let token = Self.bearer(request), let device = devices.authenticate(token, now: now) else {
            limiter.recordFailure(peer, now: now)
            var response = ShareResponse.unauthorized
            response.closeAfter = true
            return .refuse(response)
        }
        do {
            guard let inbox else { throw SaveInbox.Refusal.off }
            return .accept(try inbox.begin(titleID: request.segments[2], length: length), device: device)
        } catch let refusal as SaveInbox.Refusal {
            switch refusal {
            case .off: return .refuse(.status(403, close: true))
            case .notAGame: return .refuse(.status(404, close: true))
            case .tooLarge: return .refuse(.status(413, close: true))
            case .noRoom: return .refuse(.status(507, close: true))
            case .notAZip, .cut: return .refuse(.status(400, close: true))
            }
        } catch {
            return .refuse(.status(500, close: true))
        }
    }

    // MARK: routes

    private func route(_ segments: [String], request: HTTPRequest) -> ShareResponse {
        switch segments.count {
        case 2 where segments[1] == "games":
            return .encoded(RemoteListing(games: library.listing()))
        case 3 where segments[1] == "games":
            guard let game = library.game(titleID: segments[2]), TitleID.isGame(segments[2]) else { return .notFound }
            return .encoded(game.listing)
        case 2 where segments[1] == "buildable" && request.method != "POST":
            // Without the player's permission there is nothing to offer, and the phone shows nothing.
            guard let builds, builds.allowsBuilds else { return .encoded(BuildableListing(games: [], allowed: false)) }
            let built = Set(library.listing().map(\.titleID))
            return .encoded(BuildableListing(games: builds.buildable().filter { !built.contains($0.titleID) }))
        case 3 where segments[1] == "build" && request.method == "POST":
            guard let builds, builds.allowsBuilds else { return .status(403) }
            guard TitleID.isGame(segments[2]), let id = TitleID(segments[2]),
                  !library.listing().contains(where: { $0.titleID == id.description }) else { return .notFound }
            switch builds.requestBuild(titleID: id.description) {
            case .accepted: return .json(200, ["state": "queued"])
            case .notFound: return .notFound
            case .busy: return .status(423)
            }
        case 3 where segments[1] == "saves" && request.method != "POST":
            // The copies this Mac holds of a game, for the phone to put back: only while the player takes copies at all.
            do {
                let list = try inbox?.copies(titleID: segments[2]) ?? { throw SaveInbox.Refusal.off }()
                return .encoded(SaveCopyListing(copies: list.map { SaveCopyListing.Entry(name: $0.name, size: $0.size) }))
            } catch SaveInbox.Refusal.off { return .status(403) } catch { return .notFound }
        case 4 where segments[1] == "saves" && request.method != "POST":
            do {
                guard let inbox else { return .status(403) }
                let opened = try inbox.open(titleID: segments[2], name: segments[3])
                var response = ShareResponse(status: 200, contentType: "application/octet-stream", body: .file(opened, offset: 0, length: opened.size))
                if request.method == "HEAD" { opened.close(); response.body = .none; response.headLength = opened.size }
                return response
            } catch SaveInbox.Refusal.off { return .status(403) } catch { return .notFound }
        case 4 where segments[1] == "games" && segments[3] == "icon":
            guard TitleID.isGame(segments[2]), let icon = library.icon(titleID: segments[2]) else { return .notFound }
            var response = ShareResponse(status: 200, contentType: "image/png", body: .data(icon))
            response.headers.append(("Cache-Control", "no-store"))
            return response
        case 6... where segments[1] == "games" && segments[4] == "files":
            guard TitleID.isGame(segments[2]), FileDigest.isSHA256(segments[3]) else { return .notFound }
            return file(titleID: segments[2], revision: segments[3], path: segments[5...].joined(separator: "/"), request: request)
        default:
            return .notFound
        }
    }

    private func file(titleID: String, revision: String, path: String, request: HTTPRequest) -> ShareResponse {
        let opened: OpenedFile
        do { opened = try library.open(titleID: titleID, revision: revision, path: path) }
        catch SharedLibraryError.changed { return .status(409) }
        catch { return .notFound }

        let size = opened.size
        var offset: Int64 = 0
        var last = size - 1
        var status = 200
        switch HTTPParser.range(request.header("range")) {
        case .whole:
            break
        case .invalid:
            opened.close()
            return .status(416)
        case .from(let first, let through):
            guard first < UInt64(size) || (size == 0 && first == 0) else {
                opened.close()
                var response = ShareResponse.status(416)
                response.headers.append(("Content-Range", "bytes */\(size)"))
                return response
            }
            offset = Int64(first)
            if let through { last = min(Int64(through), size - 1) }
            status = 206
        }
        let length = max(last - offset + 1, 0)
        var response = ShareResponse(status: status, contentType: "application/octet-stream")
        response.headers.append(("Accept-Ranges", "bytes"))
        response.headers.append(("ETag", "\"\(revision.prefix(16))-\(size)\""))
        if status == 206 { response.headers.append(("Content-Range", "bytes \(offset)-\(last)/\(size)")) }
        if request.method == "HEAD" {
            opened.close()
            response.body = .none
            response.headLength = length
        } else {
            response.body = .file(opened, offset: offset, length: length)
            response.note = "\(titleID)/\(path)"
        }
        return response
    }

    // MARK: pairing

    private func pair(_ request: HTTPRequest, peer: String, now: Date) -> ShareResponse {
        guard limiter.allowsPairing(now: now) else { return .status(429, close: true) }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let name = object["name"] as? String, name.utf8.count <= 256,
              let nonce = object["nonce"] as? String, nonce.count == 32, nonce.allSatisfy(\.isHexDigit),
              let proof = object["proof"] as? String else {
            limiter.recordFailure(peer, now: now)
            return .status(400, close: true)
        }
        // One answer for every way a pairing can fail (no code showing, an old one, a wrong proof): the phone learns
        // nothing about which, and a stranger learns nothing about whether the Mac is waiting for a phone.
        // The code's key or the QR code's: whichever the phone used.
        guard let key = pairing.beginAttempt(now: now).first(where: {
            PairingProof.isValid(proof, key: $0, role: "c", pin: pin, nonce: nonce, subject: name)
        }) else {
            pairing.failAttempt()
            limiter.recordFailure(peer, now: now)
            var response = ShareResponse.unauthorized
            response.closeAfter = true
            return response
        }
        pairing.succeed()
        guard let (device, token) = try? devices.add(name: name, now: now) else { return .status(500, close: true) }
        var response = ShareResponse.json(200, ["token": token, "name": self.name,
                                                "proof": PairingProof.serverProof(key: key, pin: pin, nonce: nonce, token: token)])
        response.deviceID = device.id
        response.note = "paired \(device.name)"
        return response
    }

    // MARK: pairing by comparing a number

    /// The phone promises its nonce (`request`), learns the Mac's, reveals its own (`reveal`), and both screens show the
    /// same six digits (`PairingProof.number`). The phone's `confirm` is answered with a token only after the player
    /// pressed Allow on this Mac, so nothing is issued on the phone's word alone, and the phone's own "same number" is what
    /// makes it ask.
    private func compare(_ step: String, _ request: HTTPRequest, peer: String, now: Date) -> ShareResponse {
        // Only a new request counts against the ten a minute: the phone's polling of `confirm` is one a second for two minutes.
        guard step != "request" || limiter.allowsPairing(now: now) else { return .status(429, close: true) }
        guard limiter.allows(peer, now: now) else { return .status(429, close: true) }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let commit = object["commit"] as? String, FileDigest.isSHA256(commit) else {
            limiter.recordFailure(peer, now: now)
            return .status(400, close: true)
        }
        func refused() -> ShareResponse {
            limiter.recordFailure(peer, now: now)
            var response = ShareResponse.unauthorized
            response.closeAfter = true
            return response
        }
        switch step {
        case "request":
            guard let name = object["name"] as? String, !name.isEmpty, name.utf8.count <= 256 else {
                limiter.recordFailure(peer, now: now)
                return .status(400, close: true)
            }
            switch pairing.request(peer: peer, name: name, commit: commit, now: now) {
            case .closed: return refused()
            case .busy: return .status(423)
            case .nonce(let nonce): return .json(200, ["nonce": nonce])
            }
        case "reveal":
            guard let nonce = object["nonce"] as? String, nonce.count == 32, nonce.allSatisfy(\.isHexDigit),
                  pairing.reveal(commit: commit, phoneNonce: nonce, now: now) else { return refused() }
            return .json(200, [:])
        case "cancel":
            pairing.cancelRequest(commit: commit)
            return .json(200, [:])
        default:
            switch pairing.poll(commit: commit, now: now) {
            case .unknown: return refused()
            case .waiting: return .json(200, ["state": "waiting"])
            case .denied: return .status(403)
            case .approved(let name):
                guard let (device, token) = try? devices.add(name: name, now: now) else { return .status(500, close: true) }
                var response = ShareResponse.json(200, ["state": "approved", "token": token, "name": self.name])
                response.deviceID = device.id
                response.note = "paired \(device.name)"
                return response
            }
        }
    }

    static func bearer(_ request: HTTPRequest) -> String? {
        guard let header = request.header("authorization"), header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst(7))
        return token.count == 64 ? token : nil
    }
}

/// The one pairing that can be open: a code on the Mac's screen and a QR code that says the same thing, good for two
/// minutes and three wrong proofs, and for one phone. Their keys are derived once, when it opens, so a proof costs one
/// MAC, not a hundred thousand rounds.
///
/// A phone may also ask to pair by comparing a number (`PairingProof.number`) while the window is open: one request at a
/// time, shown on the Mac with the number once the phone has revealed its nonce, and only the player's Allow lets it through.
public final class PairingSessions: @unchecked Sendable {
    public static let lifetime: TimeInterval = 120
    public static let attempts = 3

    public struct Offer: Equatable, Sendable {
        public let code: String
        /// What the QR code carries (`PairLink`).
        public let secret: String
        public let expires: Date
    }

    /// A phone asking to pair by number. `number` is nil until the phone has revealed its nonce: Allow waits for it.
    public struct Request: Equatable, Sendable {
        public let name: String
        public let number: String?
        public let expires: Date
    }

    enum RequestOutcome: Equatable { case nonce(String), closed, busy }
    enum PollOutcome: Equatable { case unknown, waiting, denied, approved(name: String) }

    private enum Decision { case approved, denied }
    private struct Pending {
        var peer: String
        var name: String
        var commit: String
        var macNonce: String
        var number: String?
        var decision: Decision?
    }
    private struct Open {
        var code: String
        var secret: String
        var keys: [SymmetricKey]
        var expires: Date
        var failed: Int
        var pending: Pending?
    }
    private let lock = NSLock()
    private var open: Open?
    private let pin: String
    private let onChange: @Sendable () -> Void

    init(pin: String, onChange: @escaping @Sendable () -> Void = {}) {
        self.pin = pin
        self.onChange = onChange
    }

    public func begin(now: Date = Date()) -> Offer? {
        let code = PairingProof.makeCode()
        let secret = PairingProof.makeSecret()
        guard let codeKey = PairingProof.key(code: code, pin: pin), let qrKey = PairingProof.key(secret: secret, pin: pin) else { return nil }
        let expires = now.addingTimeInterval(Self.lifetime)
        lock.withLock { open = Open(code: code, secret: secret, keys: [codeKey, qrKey], expires: expires, failed: 0, pending: nil) }
        return Offer(code: code, secret: secret, expires: expires)
    }

    public func cancel() {
        let had = lock.withLock { () -> Bool in defer { open = nil }; return open != nil }
        if had { onChange() }
    }

    public var current: Offer? {
        lock.withLock { open.flatMap { $0.expires > Date() ? Offer(code: $0.code, secret: $0.secret, expires: $0.expires) : nil } }
    }

    /// The phone waiting to be allowed, if there is one.
    public var request: Request? {
        lock.withLock {
            guard let open, open.expires > Date(), let pending = open.pending, pending.decision == nil else { return nil }
            return Request(name: pending.name, number: pending.number, expires: open.expires)
        }
    }

    /// Allow: only once the number is showing, so a phone cannot be let in before the player had something to compare.
    public func approve() { decide(.approved) }
    public func deny() { decide(.denied) }

    private func decide(_ decision: Decision) {
        let changed = lock.withLock { () -> Bool in
            guard open?.pending?.number != nil, open?.pending?.decision == nil else { return false }
            open?.pending?.decision = decision
            return true
        }
        if changed { onChange() }
    }

    func beginAttempt(now: Date) -> [SymmetricKey] {
        lock.withLock {
            guard let open, open.expires > now else { return [] }
            return open.keys
        }
    }

    func failAttempt() {
        if lock.withLock({ burn() }) { onChange() }
    }

    /// One more wrong proof or reveal; the window closes at the third. Called with the lock held.
    private func burn() -> Bool {
        guard open != nil else { return false }
        open?.failed += 1
        if let failed = open?.failed, failed >= Self.attempts { open = nil; return true }
        return false
    }

    func succeed() {
        lock.withLock { open = nil }
        onChange()
    }

    // MARK: asking by number

    func request(peer: String, name: String, commit: String, now: Date) -> RequestOutcome {
        let outcome = lock.withLock { () -> RequestOutcome in
            guard open != nil, open!.expires > now else { return .closed }
            // A second phone does not push the first one off the screen; the same phone asking again does.
            if let pending = open?.pending, pending.peer != peer, pending.decision == nil { return .busy }
            let nonce = PairingProof.nonce()
            open?.pending = Pending(peer: peer, name: name, commit: commit, macNonce: nonce, number: nil, decision: nil)
            return .nonce(nonce)
        }
        if case .nonce = outcome { onChange() }
        return outcome
    }

    func reveal(commit: String, phoneNonce: String, now: Date) -> Bool {
        let ok = lock.withLock { () -> Bool in
            guard open != nil, open!.expires > now, let pending = open?.pending, pending.commit == commit,
                  pending.number == nil else { return false }
            guard PairingProof.commit(nonce: phoneNonce, name: pending.name) == commit else {
                open?.pending = nil
                _ = burn()
                return false
            }
            open?.pending?.number = PairingProof.number(pin: pin, phoneNonce: phoneNonce, macNonce: pending.macNonce)
            return true
        }
        onChange()
        return ok
    }

    func poll(commit: String, now: Date) -> PollOutcome {
        let outcome = lock.withLock { () -> PollOutcome in
            guard open != nil, open!.expires > now, let pending = open?.pending, pending.commit == commit,
                  pending.number != nil else { return .unknown }
            switch pending.decision {
            case nil: return .waiting
            case .denied?:
                open?.pending = nil
                return .denied
            case .approved?:
                open = nil
                return .approved(name: pending.name)
            }
        }
        if outcome != .waiting, outcome != .unknown { onChange() }
        return outcome
    }

    func cancelRequest(commit: String) {
        let had = lock.withLock { () -> Bool in
            guard open?.pending?.commit == commit else { return false }
            open?.pending = nil
            return true
        }
        if had { onChange() }
    }
}

/// The limits that keep one neighbour from using up the server: failed tokens per address, pairing attempts in all.
public final class RateLimiter: @unchecked Sendable {
    static let failuresAllowed = 5
    static let window: TimeInterval = 60
    static let pairingPerMinute = 10
    static let maxAddresses = 1024

    private let lock = NSLock()
    private var failures: [String: [Date]] = [:]
    private var pairings: [Date] = []

    public init() {}

    func allows(_ address: String, now: Date) -> Bool {
        lock.withLock {
            let recent = (failures[address] ?? []).filter { now.timeIntervalSince($0) < Self.window }
            failures[address] = recent.isEmpty ? nil : recent
            return recent.count < Self.failuresAllowed
        }
    }

    func recordFailure(_ address: String, now: Date) {
        lock.withLock {
            if failures.count >= Self.maxAddresses, failures[address] == nil {
                // A flood from many addresses must not grow this without bound: the quietest forgets first.
                if let oldest = failures.min(by: { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) })?.key {
                    failures[oldest] = nil
                }
            }
            failures[address, default: []].append(now)
        }
    }

    func allowsPairing(now: Date) -> Bool {
        lock.withLock {
            pairings = pairings.filter { now.timeIntervalSince($0) < Self.window }
            guard pairings.count < Self.pairingPerMinute else { return false }
            pairings.append(now)
            return true
        }
    }
}

/// How many connections the server holds: in all, and from one address.
public final class ConnectionGate: @unchecked Sendable {
    public static let total = 16
    public static let perAddress = 4

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var all = 0

    public init() {}

    public func admit(_ address: String) -> Bool {
        lock.withLock {
            guard all < Self.total, counts[address, default: 0] < Self.perAddress else { return false }
            all += 1
            counts[address, default: 0] += 1
            return true
        }
    }

    public func release(_ address: String) {
        lock.withLock {
            all = max(all - 1, 0)
            if let count = counts[address] { counts[address] = count > 1 ? count - 1 : nil }
        }
    }

    public var active: Int { lock.withLock { all } }
}
