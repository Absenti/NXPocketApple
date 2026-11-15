import Foundation
import Network
import NXPocketKit
import Security

/// A game an iPhone is downloading from this Mac right now, for the window to show.
public struct ShareTransfer: Identifiable, Equatable, Sendable {
    public var id: String
    public var device: String
    public var name: String
    public var sent: Int64
    public var total: Int64
    public var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }
}

/// The launcher's door for paired iPhones: TLS 1.3 on the local network, the API of `docs/SHARING.md` §4, read
/// only. It listens only while the player has switched sharing on, and answers only peers on the local network.
public final class ShareServer: @unchecked Sendable {
    public static let serviceType = "_nxpocket._tcp"

    private let identity: ServerIdentity
    private let router: ShareRouter
    public let devices: PairedDevices
    public let pairing: PairingSessions
    private let gate = ConnectionGate()
    private let log: @Sendable (String) -> Void
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.nxpocketapple.share", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var live: [UUID: Live] = [:]
    private var transfers = 0
    private var activity: NSObjectProtocol?
    private var progress: [String: (transfer: ShareTransfer, last: Date)] = [:]
    private var lastNotified = Date.distantPast

    private struct Live {
        var connection: NWConnection
        var task: Task<Void, Never>?
        var deviceID: String?
    }

    /// The key a phone pins: shown in the launcher so the player can compare it with what the phone says.
    public var pin: String { identity.pin }
    public var activeConnections: Int { gate.active }

    public init(identity: ServerIdentity, library: SharedLibrary, devices: PairedDevices, name: String, saves: SaveInbox? = nil, builds: BuildPort? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }, onChange: @escaping @Sendable () -> Void = {}) {
        self.identity = identity
        self.devices = devices
        self.log = log
        self.onChange = onChange
        let sessions = PairingSessions(pin: identity.pin, onChange: onChange)
        self.pairing = sessions
        self.router = ShareRouter(library: library, devices: devices, pairing: sessions, limiter: RateLimiter(), pin: identity.pin, name: name, inbox: saves, builds: builds)
    }

    // MARK: lifecycle

    /// Starts listening and returns the port. `port` 0 lets the system choose; the launcher keeps the one it got.
    public func start(port: UInt16 = 0, advertise: Bool = true, serviceName: String? = nil) async throws -> UInt16 {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else {
            throw NXPocketError(.signingFailed, "the sharing identity could not be used")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw NXPocketError(.transferFailed, "port \(port) is not valid") }
        let listener = try NWListener(using: parameters, on: endpointPort)
        if advertise {
            listener.service = NWListener.Service(name: serviceName, type: Self.serviceType, txtRecord: NWTXTRecord(["v": "1", "fp": String(identity.pin.prefix(8))]))
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { continuation.resume(returning: listener.port?.rawValue ?? port) }
                case .failed(let error):
                    if once.fire() { continuation.resume(throwing: NXPocketError(.transferFailed, "sharing could not start: \(error.localizedDescription)")) }
                    listener.cancel()
                case .cancelled:
                    if once.fire() { continuation.resume(throwing: NXPocketError(.cancelled, "sharing was stopped before it started")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
        log("sharing is on: listening on port \(bound)")
        return bound
    }

    public func stop() {
        let (listener, connections) = lock.withLock { () -> (NWListener?, [Live]) in
            defer { self.listener = nil; live.removeAll() }
            return (self.listener, Array(live.values))
        }
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        for entry in connections {
            entry.task?.cancel()
            entry.connection.cancel()
        }
        pairing.cancel()
        endActivity(all: true)
        log("sharing is off")
    }

    // MARK: pairing and revocation

    public func beginPairing() -> PairingSessions.Offer? {
        let offer = pairing.begin()
        if offer != nil { log("a pairing code is showing") }
        onChange()
        return offer
    }

    public func cancelPairing() { pairing.cancel() }

    /// Removes a phone and cuts every connection it has open, at once.
    public func revoke(deviceID: String) {
        guard let device = devices.revoke(id: deviceID) else { return }
        let doomed = lock.withLock { live.filter { $0.value.deviceID == deviceID } }
        for entry in doomed.values {
            entry.task?.cancel()
            entry.connection.cancel()
        }
        log("revoked \(device.name)")
        onChange()
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        // Before the handshake: a peer that is not on this network never gets as far as a certificate.
        guard let peer = Self.address(of: connection.endpoint), LocalNetworkAddress.isLocal(peer), gate.admit(peer) else {
            connection.cancel()
            return
        }
        let id = UUID()
        lock.withLock { live[id] = Live(connection: connection, task: nil, deviceID: nil) }
        let task = Task { [weak self] in
            await self?.serve(connection, peer: peer, id: id)
            self?.finish(id, peer: peer)
        }
        lock.withLock { live[id]?.task = task }
    }

    private func finish(_ id: UUID, peer: String) {
        let removed = lock.withLock { live.removeValue(forKey: id) }
        removed?.connection.cancel()
        gate.release(peer)
        onChange()
    }

    static func address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        default: return nil
        }
    }

    private func serve(_ connection: NWConnection, peer: String, id: UUID) async {
        guard await Self.ready(connection, queue: queue, timeout: 10) else { return }
        var buffer = Data()
        var first = true
        while !Task.isCancelled {
            let request: HTTPRequest
            var uploadLength: Int64?
            do {
                guard let parsed = try await Self.readRequest(connection, buffer: &buffer, first: first) else { return }
                request = parsed.request
                uploadLength = parsed.upload
            } catch {
                return
            }
            first = false
            if let length = uploadLength {
                // The one request with a long body: answered from its head, and the connection closed after it either way.
                await takeUpload(request, length: length, from: connection, buffer: &buffer, peer: peer, id: id)
                return
            }
            var response = router.respond(to: request, peer: peer)
            let closes = response.closeAfter || request.header("connection")?.lowercased() == "close"
            if let deviceID = response.deviceID { lock.withLock { live[id]?.deviceID = deviceID } }
            if let note = response.note, note.hasPrefix("paired") { log(note); onChange() }
            response.closeAfter = closes
            do { try await write(response, on: connection, head: request.method == "HEAD", deviceID: response.deviceID) }
            catch { return }
            if closes { return }
        }
    }

    // MARK: receiving a copy of saves

    private func takeUpload(_ request: HTTPRequest, length: Int64, from connection: NWConnection, buffer: inout Data, peer: String, id: UUID) async {
        var response: ShareResponse
        var upload: SaveInbox.Upload?
        var device: PairedDevice?
        switch router.authorizeUpload(request, length: length, peer: peer) {
        case .refuse(let refusal):
            response = refusal
        case .accept(let opened, let who):
            upload = opened
            device = who
            response = .status(200)
        }
        if let upload, let device {
            lock.withLock { live[id]?.deviceID = device.id }
            beginActivity()
            defer { endActivity(all: false) }
            do {
                var remaining = length
                // The part of the body that came with the head, then the rest as it arrives: thirty seconds of quiet cut it.
                if !buffer.isEmpty {
                    let take = Int(min(Int64(buffer.count), remaining))
                    try upload.write(buffer.prefix(take))
                    remaining -= Int64(take)
                }
                buffer = Data()
                while remaining > 0 {
                    try Task.checkCancellation()
                    if !devices.contains(id: device.id) { throw CancellationError() }
                    guard let chunk = try await Self.receive(connection, timeout: 30) else { throw SaveInbox.Refusal.cut }
                    let take = Int(min(Int64(chunk.count), remaining))
                    try upload.write(chunk.prefix(take))
                    remaining -= Int64(take)
                }
                let stored = try upload.commit()
                log("saves of \(request.segments[2]) from \(device.name): \(GameImporter.bytes(length)) kept as \(stored.lastPathComponent)")
                response = .json(200, ["stored": stored.lastPathComponent])
            } catch {
                upload.abort()
                log("saves of \(request.segments[2]) from \(device.name) were not kept")
                response = .status((error as? SaveInbox.Refusal) == .tooLarge ? 413 : 400)
            }
        }
        response.closeAfter = true
        try? await write(response, on: connection, head: false, deviceID: response.deviceID)
        onChange()
    }

    // MARK: reading

    /// The next request, or nil when the peer is gone or sent something the parser refuses (which is answered first).
    private static func readRequest(_ connection: NWConnection, buffer: inout Data, first: Bool) async throws -> (request: HTTPRequest, upload: Int64?)? {
        while true {
            switch HTTPParser.parse(buffer) {
            case .request(let request, let consumed):
                buffer = buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
                return (request, nil)
            case .upload(let request, let length, let consumed):
                buffer = buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
                return (request, length)
            case .failure(let status):
                try? await send(ShareResponse.status(status, close: true).wire(), on: connection)
                return nil
            case .incomplete:
                // Ten seconds to deliver a request, one minute of quiet between two.
                let wait: TimeInterval = buffer.isEmpty && !first ? 60 : 10
                guard let chunk = try await receive(connection, timeout: wait) else { return nil }
                buffer.append(chunk)
            }
        }
    }

    /// Cuts the connection when `seconds` pass without the caller cancelling the watchdog first. A cancelled sleep throws, and
    /// that is the caller finishing in time: it must not cut anything.
    private static func watchdog(_ connection: NWConnection, after seconds: TimeInterval) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            connection.cancel()
        }
    }

    private static func receive(_ connection: NWConnection, timeout: TimeInterval) async throws -> Data? {
        let watchdog = Self.watchdog(connection, after: timeout)
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(returning: isComplete ? nil : Data()) }
            }
        }
    }

    // MARK: writing

    private func write(_ response: ShareResponse, on connection: NWConnection, head: Bool, deviceID: String?) async throws {
        var length: Int64 = 0
        switch response.body {
        case .none: length = response.headLength ?? 0
        case .data(let data): length = Int64(data.count)
        case .file(_, _, let count): length = count
        }
        let header = response.head(contentLength: length)
        guard case .file(let file, let offset, let count) = response.body, !head else {
            if case .file(let file, _, _) = response.body { file.close() }
            try await Self.send(header + (head ? Data() : response.dataBody), on: connection)
            return
        }
        defer { file.close() }
        beginActivity()
        defer { endActivity(all: false) }
        let name = deviceID.flatMap { devices.device(id: $0)?.name } ?? "an iPhone"
        var sent: Int64 = 0
        do {
            try await Self.send(header, on: connection)
            var position = offset
            let end = offset + count
            let chunk = 256 * 1024
            var buffer = [UInt8](repeating: 0, count: chunk)
            while position < end {
                try Task.checkCancellation()
                // A phone revoked in the middle of a transfer is cut, not left to finish it.
                if let deviceID, !devices.contains(id: deviceID) { throw CancellationError() }
                let want = Int(min(Int64(chunk), end - position))
                let read = buffer.withUnsafeMutableBytes { pread(file.descriptor, $0.baseAddress, want, off_t(position)) }
                guard read > 0 else { throw NXPocketError(.transferFailed, "the file ended early") }
                try await Self.send(Data(buffer[0..<read]), on: connection)
                position += Int64(read)
                sent += Int64(read)
                record(read, note: response.note, deviceID: deviceID, device: name)
            }
            if count >= 1 << 20, let note = response.note { log("sent \(note) to \(name) (\(GameImporter.bytes(count)))") }
        } catch {
            if count >= 1 << 20, let note = response.note { log("\(note) to \(name) was cut after \(GameImporter.bytes(sent))") }
            throw error
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        // A phone that stops reading holds a connection, and a slot, for no more than thirty seconds at a time.
        let watchdog = Self.watchdog(connection, after: 30)
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func ready(_ connection: NWConnection, queue: DispatchQueue, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { continuation.resume(returning: true) }
                case .failed, .cancelled: if once.fire() { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.fire() { connection.cancel(); continuation.resume(returning: false) }
            }
        }
    }

    // MARK: staying awake

    /// A transfer of gigabytes must not be cut by the Mac going to sleep on its own.
    private func beginActivity() {
        lock.withLock {
            transfers += 1
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Sending a game to an iPhone")
            }
        }
        onChange()
    }

    private func endActivity(all: Bool) {
        lock.withLock {
            transfers = all ? 0 : max(transfers - 1, 0)
            if transfers == 0, let token = activity {
                ProcessInfo.processInfo.endActivity(token)
                activity = nil
            }
        }
        onChange()
    }

    public var transferring: Bool { lock.withLock { transfers > 0 } }

    /// The games iPhones are downloading: one entry per game and phone, from its first byte until it has all of them or has been
    /// quiet for fifteen seconds (a phone that paused, or lost the network, is no longer "downloading").
    public var activeTransfers: [ShareTransfer] {
        lock.withLock {
            let now = Date()
            progress = progress.filter { now.timeIntervalSince($0.value.last) < 15 && $0.value.transfer.sent < $0.value.transfer.total }
            return progress.values.map(\.transfer).sorted { $0.id < $1.id }
        }
    }

    private func record(_ bytes: Int, note: String?, deviceID: String?, device: String) {
        guard let note, let titleID = note.split(separator: "/").first.map(String.init),
              let game = router.library.game(titleID: titleID) else { return }
        let key = "\(deviceID ?? device)|\(titleID)"
        let notify = lock.withLock { () -> Bool in
            var entry = progress[key]?.transfer ?? ShareTransfer(id: key, device: device, name: game.package.name, sent: 0, total: game.package.totalSize)
            entry.sent += Int64(bytes)
            progress[key] = (entry, Date())
            let now = Date()
            defer { if now.timeIntervalSince(lastNotified) > 0.5 { lastNotified = now } }
            return now.timeIntervalSince(lastNotified) > 0.5
        }
        if notify { onChange() }
    }
}

/// Fires once, from whichever callback gets there first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}

extension ShareResponse {
    private static let reasons: [Int: String] = [200: "OK", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized",
                                                 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 411: "Length Required", 423: "Locked", 413: "Content Too Large",
                                                 507: "Insufficient Storage",
                                                 414: "URI Too Long", 416: "Range Not Satisfiable", 429: "Too Many Requests",
                                                 431: "Request Header Fields Too Large", 500: "Internal Server Error", 505: "HTTP Version Not Supported"]

    func head(contentLength: Int64) -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")",
                     "Content-Type: \(contentType)",
                     "Content-Length: \(contentLength)",
                     "Connection: \(closeAfter ? "close" : "keep-alive")",
                     "Cache-Control: no-store",
                     "X-Content-Type-Options: nosniff"]
        lines += headers.map { "\($0.0): \($0.1)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    var dataBody: Data {
        if case .data(let data) = body { return data }
        return Data()
    }

    func wire() -> Data { head(contentLength: Int64(dataBody.count)) + dataBody }
}
