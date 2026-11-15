import Foundation
import Security

/// The system's background transfer service, used for the big files of a game: segments (`SegmentedSource`) are handed to it and it goes
/// on fetching them while the app is suspended or stopped, then wakes the app when it has nothing more to do (`handleEvents`).
///
/// The rules of `HTTPSession` hold here too: the server is known by its pinned key or by the system's judgement of its certificate, no
/// redirect is followed, no proxy, no cookie, no cache, nothing over cellular. A segment is accepted only as exactly the range that was
/// asked for (`problem(response:size:for:)`), kept as a file in a folder of its own until the downloader reads it, and never trusted
/// beyond that: the downloader checks sizes and hashes as it always did.
///
/// Everything a task needs to be judged is in the task itself (its description), because the app that receives the result may be a new
/// process that knows nothing of the one that asked.
public final class BackgroundTransfers: NSObject, SegmentTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let identifier = "dev.nxpocketapple.transfers"

    /// The service of this app, or nil outside an app (a command-line tool or test has no background service to give).
    public static let shared: BackgroundTransfers? = {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return BackgroundTransfers(stash: defaultStash)
    }()

    /// Application Support, not Documents: the player does not see it and the system does not purge it.
    public static var defaultStash: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Transfers", isDirectory: true)
    }

    /// What a task carries to be judged by: which segment it is, and the bytes it must be.
    struct Info: Codable, Equatable {
        var key: String
        var first: UInt64
        var length: UInt64
        var total: UInt64
    }

    private let stash: URL
    private let lock = NSLock()
    private var session: URLSession!
    private var waiters: [String: [(id: UUID, continuation: CheckedContinuation<URL, Error>)]] = [:]
    private var failures: [String: Error] = [:]
    private var trust: [String: SegmentTrust] = [:]
    private var refused: [String: String] = [:]
    private var eventsDone: (() -> Void)?
    /// After the service has delivered what it had, the app is kept awake this long, so the segments just finished are read and the next
    /// ones asked for before it is suspended again.
    public var holdAfterEvents: TimeInterval = 15

    public init(stash: URL, identifier: String = BackgroundTransfers.identifier, idleTimeout: TimeInterval = SharingLimits.idleTimeout) {
        self.stash = stash
        super.init()
        try? FileManager.default.createDirectory(at: stash, withIntermediateDirectories: true)
        var folder = stash
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        trust = Self.loadTrust(from: stash)
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    // MARK: SegmentTransport

    public func enqueue(_ segment: SegmentRequest) async throws {
        guard segment.length > 0, segment.first + segment.length <= segment.total, let url = segment.request.url, url.scheme == "https",
              let host = url.host else {
            throw PackageSourceError.malformed("a part of a file was asked for in a way that makes no sense")
        }
        if readyFile(segment.key, length: segment.length) != nil { return }
        if await session.allTasks.contains(where: { Self.info(of: $0)?.key == segment.key }) { return }
        lock.withLock { failures[segment.key] = nil }
        setTrust(segment.trust, for: "\(host):\(url.port ?? 443)")
        var request = segment.request
        request.setValue("bytes=\(segment.first)-\(segment.first + segment.length - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = false
        let task = session.downloadTask(with: request)
        let info = Info(key: segment.key, first: segment.first, length: segment.length, total: segment.total)
        task.taskDescription = (try? JSONEncoder().encode(info)).flatMap { String(data: $0, encoding: .utf8) }
        task.resume()
    }

    public func completion(of key: String) async throws -> URL {
        if let ready = readyFile(key) { return ready }
        if let failure = takeFailure(key) { throw failure }
        let alive = await session.allTasks.contains { Self.info(of: $0)?.key == key }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                enum Outcome { case ready(URL), failed(Error), lost, waiting }
                // The check and the registration are one step: a segment that finishes between them would be waited for for ever.
                let outcome = lock.withLock { () -> Outcome in
                    if let ready = readyFileLocked(key) { return .ready(ready) }
                    if let failure = failures.removeValue(forKey: key) { return .failed(failure) }
                    guard alive else { return .lost }
                    waiters[key, default: []].append((id, continuation))
                    return .waiting
                }
                switch outcome {
                case .ready(let url): continuation.resume(returning: url)
                case .failed(let error): continuation.resume(throwing: error)
                case .lost: continuation.resume(throwing: PackageSourceError.unreachable("the transfer of a part of the file was lost"))
                case .waiting: break
                }
            }
        } onCancel: {
            let pending = lock.withLock { () -> CheckedContinuation<URL, Error>? in
                guard let index = waiters[key]?.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters[key]?.remove(at: index).continuation
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    public func cancel(keys: [String]) async {
        let wanted = Set(keys)
        for task in await session.allTasks where Info.key(of: task).map(wanted.contains) == true { task.cancel() }
    }

    /// A game's unfinished download is forgotten: what is under way stops and what finished is deleted.
    public func discard(titleID: String) async {
        let marker = "-\(titleID.uppercased())-"
        for task in await session.allTasks where Info.key(of: task)?.contains(marker) == true { task.cancel() }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: stash.path)) ?? [] where name.contains(marker) {
            try? FileManager.default.removeItem(at: stash.appendingPathComponent(name))
        }
    }

    /// Whether the service holds anything of ours: a segment under way, or one that finished and was not read yet.
    public func hasWork() async -> Bool {
        if !(await session.allTasks).isEmpty { return true }
        return ((try? FileManager.default.contentsOfDirectory(atPath: stash.path)) ?? []).contains { $0.hasSuffix(".part") }
    }

    // MARK: waking

    /// The app was started, or woken, because the service has something to say. The handler is the system's, to be called once what was
    /// said has been dealt with (`urlSessionDidFinishEvents`).
    public func handleEvents(_ completion: @escaping () -> Void) {
        lock.withLock { eventsDone = completion }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (() -> Void)? in
            defer { eventsDone = nil }
            return eventsDone
        }
        guard let handler else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdAfterEvents) { handler() }
    }

    // MARK: files

    private func file(for key: String) -> URL { stash.appendingPathComponent(key + ".part") }

    private func readyFile(_ key: String, length: UInt64? = nil) -> URL? {
        lock.withLock { readyFileLocked(key, length: length) }
    }

    private func readyFileLocked(_ key: String, length: UInt64? = nil) -> URL? {
        let url = file(for: key)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil else { return nil }
        if let length, size != length { try? FileManager.default.removeItem(at: url); return nil }
        return url
    }

    private func takeFailure(_ key: String) -> Error? { lock.withLock { failures.removeValue(forKey: key) } }

    /// The segment is whole, or it is not: the waiters are told either way, and a failure is kept for a reader that comes later.
    private func settle(_ key: String, _ outcome: Result<URL, Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<URL, Error>] in
            let list = waiters.removeValue(forKey: key) ?? []
            if list.isEmpty, case .failure(let error) = outcome, !(error is CancellationError) { failures[key] = error }
            return list.map(\.continuation)
        }
        for continuation in pending { continuation.resume(with: outcome) }
    }

    // MARK: what a task is, and whether it delivered it

    static func info(of task: URLSessionTask) -> Info? { Info.of(task) }

    /// Why a segment is not what was asked for, nil when it is exactly that. The size is the file's.
    static func problem(response: HTTPURLResponse?, size: UInt64, for info: Info) -> Error? {
        guard let response else { return PackageSourceError.malformed("no answer") }
        switch response.statusCode {
        case 206:
            guard let range = PinnedHTTPSSource.contentRange(response), range.first == info.first,
                  range.last == info.first + info.length - 1, range.total == info.total else {
                return PackageSourceError.malformed("the answer is not the part of the file that was asked for")
            }
        case 200:
            // A server that ignores Range sends the whole file: only a part that is the whole file can be that.
            guard info.first == 0, info.length == info.total else {
                return PackageSourceError.malformed("the server does not resume a download (no Range support)")
            }
        case 401, 403: return PackageSourceError.unauthorized
        case 404, 410: return PackageSourceError.notFound
        case 409: return PackageSourceError.changed
        case 423: return PackageSourceError.busy
        case 429, 503: return PackageSourceError.unreachable("the source is busy, try again in a moment")
        default: return PackageSourceError.malformed("unexpected answer \(response.statusCode)")
        }
        return size == info.length ? nil : PackageSourceError.malformed("a part of the file is \(size) bytes long, not \(info.length)")
    }

    // MARK: the servers

    /// `host:port` to how that server is trusted. Kept in a file: a task answered by a new process still needs it.
    private func setTrust(_ value: SegmentTrust, for hostPort: String) {
        let snapshot = lock.withLock { () -> [String: SegmentTrust]? in
            guard trust[hostPort] != value else { return nil }
            trust[hostPort] = value
            return trust
        }
        guard let snapshot else { return }
        let table = snapshot.mapValues(\.token)
        if let data = try? JSONEncoder().encode(table) { try? data.write(to: stash.appendingPathComponent("trust.json"), options: .atomic) }
    }

    static func loadTrust(from stash: URL) -> [String: SegmentTrust] {
        guard let data = BoundedRead.dataIfPresent(at: stash.appendingPathComponent("trust.json"), limit: 1 << 20),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table.compactMapValues(SegmentTrust.init(token:))
    }

    func trust(for hostPort: String) -> SegmentTrust? { lock.withLock { trust[hostPort] } }

    // MARK: URLSessionDelegate

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let expected = trust(for: "\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)") else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        switch expected {
        case .system:
            completionHandler(.performDefaultHandling, nil)
        case .pinned(let pin):
            guard let seen = TLSPin.fingerprint(of: serverTrust) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            if seen == pin {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                lock.withLock { refused["\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"] = seen }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = Info.of(downloadTask) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? UInt64) ?? nil
        if let problem = Self.problem(response: downloadTask.response as? HTTPURLResponse, size: size ?? 0, for: info) {
            try? FileManager.default.removeItem(at: location)
            settle(info.key, .failure(problem))
            return
        }
        // The system deletes its file when this returns: the move is made here.
        let destination = file(for: info.key)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            settle(info.key, .failure(PackageSourceError.unreachable("a part of the file could not be kept: \(error.localizedDescription)")))
            return
        }
        settle(info.key, .success(destination))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let info = Info.of(task), let error else { return }
        let hostPort = task.originalRequest?.url.flatMap { url in url.host.map { "\($0):\(url.port ?? 443)" } }
        let wrongKey = lock.withLock { () -> String? in hostPort.flatMap { refused.removeValue(forKey: $0) } }
        if let wrongKey { settle(info.key, .failure(PackageSourceError.untrusted(fingerprint: wrongKey))); return }
        if (error as? URLError)?.code == .cancelled { settle(info.key, .failure(CancellationError())); return }
        settle(info.key, .failure(PackageSourceError.unreachable(HTTPSession.explain(error))))
    }
}

extension BackgroundTransfers.Info {
    static func of(_ task: URLSessionTask) -> BackgroundTransfers.Info? {
        guard let text = task.taskDescription, text.utf8.count < 2048,
              let info = try? JSONDecoder().decode(BackgroundTransfers.Info.self, from: Data(text.utf8)) else { return nil }
        return info
    }

    static func key(of task: URLSessionTask) -> String? { of(task)?.key }
}
