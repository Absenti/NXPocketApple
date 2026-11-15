import Foundation
import Security

/// `URLSession` for one server, with the two things this app needs from it that the default does not do: the server is
/// recognised by the hash of its public key and by nothing else, and a body is handed over at the pace the consumer
/// reads it, so a gigabyte on a fast network does not queue up in memory behind a slower disk.
///
/// No redirect is followed, no proxy is used, no cookie or cache is kept, and the body is never compressed: the lengths
/// the downloader checks are the lengths on the wire.
final class HTTPSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Trust: Sendable, Equatable {
        /// Accept the key and remember it: the first contact of a pairing, where the typed code is what ties the key to
        /// the Mac the player is looking at.
        case observe
        case pinned(String)
        /// The system's own judgement of the certificate: for a web server with a certificate from an authority (a link the player made
        /// at a host of their own), which has no key to pin.
        case system
    }

    private let trust: Trust
    private let lock = NSLock()
    private var session: URLSession!
    private var transfers: [Int: HTTPTransfer] = [:]
    private var _observedPin: String?
    private var _refusedPin: String?

    init(trust: Trust, idleTimeout: TimeInterval = SharingLimits.idleTimeout, protocolClasses: [AnyClass]? = nil) {
        self.trust = trust
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.tlsMinimumSupportedProtocolVersion = trust == .system ? .TLSv12 : .TLSv13
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    var observedPin: String? { lock.withLock { _observedPin } }

    func invalidate() { session.invalidateAndCancel() }

    func start(_ request: URLRequest) -> HTTPTransfer {
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: request)
        let transfer = HTTPTransfer(task: task)
        lock.withLock { transfers[task.taskIdentifier] = transfer }
        task.resume()
        return transfer
    }

    /// A request whose body is a file, sent from the file as the network takes it: a copy of saves is small, but it is never
    /// read into memory whole.
    func upload(_ request: URLRequest, file: URL) -> HTTPTransfer {
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.uploadTask(with: request, fromFile: file)
        let transfer = HTTPTransfer(task: task)
        lock.withLock { transfers[task.taskIdentifier] = transfer }
        task.resume()
        return transfer
    }

    private func transfer(for task: URLSessionTask) -> HTTPTransfer? { lock.withLock { transfers[task.taskIdentifier] } }

    // MARK: delegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if case .system = trust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let seen = TLSPin.fingerprint(of: serverTrust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        switch trust {
        case .observe:
            lock.withLock { _observedPin = seen }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .pinned(let expected):
            if seen == expected {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                lock.withLock { _refusedPin = seen }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case .system:
            completionHandler(.performDefaultHandling, nil)   // handled above; kept for the switch
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let transfer = transfer(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        transfer.received(head: http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(for: dataTask)?.received(body: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transfer = lock.withLock { () -> HTTPTransfer? in
            transfers.removeValue(forKey: task.taskIdentifier)
        }
        let refused = lock.withLock { () -> String? in
            defer { _refusedPin = nil }
            return _refusedPin
        }
        var failure: Error?
        if let refused {
            failure = PackageSourceError.untrusted(fingerprint: refused)
        } else if let error {
            failure = (error as? URLError)?.code == .cancelled ? CancellationError() : PackageSourceError.unreachable(Self.explain(error))
        }
        transfer?.finish(failure)
    }

    static func explain(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .timedOut: return "the source stopped answering"
        case .cannotConnectToHost, .cannotFindHost: return "the source could not be reached"
        case .networkConnectionLost: return "the connection was lost"
        case .notConnectedToInternet: return "this iPhone is not on a network"
        case .secureConnectionFailed: return "the secure connection could not be made"
        default: return error.localizedDescription
        }
    }
}

/// One request in flight: its answer's head, then its body in the order it arrives, handed over on demand.
final class HTTPTransfer: @unchecked Sendable {
    /// A body that is not being read stops the network at this much held, and starts again below the low mark.
    static let highWater = 4 << 20
    static let lowWater = 1 << 20

    private let task: URLSessionDataTask
    private let lock = NSLock()
    private var head: HTTPURLResponse?
    private var headWaiter: CheckedContinuation<HTTPURLResponse, Error>?
    private var queue: [Data] = []
    private var buffered = 0
    private var suspended = false
    private var waiter: CheckedContinuation<Data?, Error>?
    private var ended = false
    private var failure: Error?
    private var declared: Int64?
    private var receivedBytes: Int64 = 0

    init(task: URLSessionDataTask) { self.task = task }

    deinit { task.cancel() }

    func cancel() { task.cancel() }

    // MARK: fed by the session

    func received(head response: HTTPURLResponse) {
        let length = response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        let waiter = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            head = response
            declared = length
            defer { headWaiter = nil }
            return headWaiter
        }
        waiter?.resume(returning: response)
    }

    func received(body data: Data) {
        let (pending, overrun, suspend) = lock.withLock { () -> (CheckedContinuation<Data?, Error>?, Bool, Bool) in
            receivedBytes += Int64(data.count)
            if let declared, receivedBytes > declared { return (nil, true, false) }
            if let waiter {
                self.waiter = nil
                return (waiter, false, false)
            }
            queue.append(data)
            buffered += data.count
            let shouldSuspend = buffered >= Self.highWater && !suspended
            if shouldSuspend { suspended = true }
            return (nil, false, shouldSuspend)
        }
        if overrun {
            // A body longer than its announced length is a server that is not speaking HTTP to us.
            task.cancel()
            finish(PackageSourceError.malformed("the body is longer than the length announced"))
        } else if let pending {
            pending.resume(returning: data)
        } else if suspend {
            task.suspend()
        }
    }

    func finish(_ error: Error?) {
        let (headPending, bodyPending, final) = lock.withLock { () -> (CheckedContinuation<HTTPURLResponse, Error>?, CheckedContinuation<Data?, Error>?, Error?) in
            guard !ended else { return (nil, nil, nil) }
            ended = true
            var error = error
            if error == nil, let declared, receivedBytes < declared {
                error = PackageSourceError.unreachable("the connection ended after \(receivedBytes) of \(declared) bytes")
            }
            failure = error
            let h = headWaiter, b = waiter
            headWaiter = nil
            waiter = nil
            return (h, b, error)
        }
        headPending?.resume(throwing: final ?? PackageSourceError.malformed("no answer"))
        if let bodyPending {
            if let final { bodyPending.resume(throwing: final) } else { bodyPending.resume(returning: nil) }
        }
    }

    // MARK: read by the consumer

    var declaredLength: Int64? { lock.withLock { declared } }

    func awaitHead() async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let ready = lock.withLock { () -> (HTTPURLResponse?, Error?, Bool) in
                    if let head { return (head, nil, true) }
                    if ended { return (nil, failure ?? PackageSourceError.malformed("no answer"), true) }
                    headWaiter = continuation
                    return (nil, nil, false)
                }
                if ready.2 {
                    if let response = ready.0 { continuation.resume(returning: response) }
                    else { continuation.resume(throwing: ready.1!) }
                }
            }
        } onCancel: { cancel() }
    }

    /// The next chunk of the body, nil at its end, an error when it broke. Reading it is what lets the network go on.
    func next() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                enum Outcome { case data(Data, resume: Bool), end, fail(Error), waiting }
                let outcome = lock.withLock { () -> Outcome in
                    if !queue.isEmpty {
                        let data = queue.removeFirst()
                        buffered -= data.count
                        let resume = suspended && buffered <= Self.lowWater
                        if resume { suspended = false }
                        return .data(data, resume: resume)
                    }
                    if ended {
                        defer { failure = nil }
                        return failure.map { .fail($0) } ?? .end
                    }
                    waiter = continuation
                    return .waiting
                }
                switch outcome {
                case .data(let data, let resume):
                    if resume { task.resume() }
                    continuation.resume(returning: data)
                case .end: continuation.resume(returning: nil)
                case .fail(let error): continuation.resume(throwing: error)
                case .waiting: break
                }
            }
        } onCancel: { cancel() }
    }

    /// The body as a stream, for a `RemoteBody`. Dropping the stream cancels the request.
    func stream() -> AsyncThrowingStream<Data, Error> {
        let guardian = Guardian(transfer: self)
        return AsyncThrowingStream(unfolding: { try await guardian.transfer.next() })
    }

    /// Lives as long as the stream does: a consumer that stops reading (a refused body, a cancelled download) lets go of
    /// the stream, and the request is cancelled instead of left to run to its end.
    private final class Guardian {
        let transfer: HTTPTransfer
        init(transfer: HTTPTransfer) { self.transfer = transfer }
        deinit { transfer.cancel() }
    }
}
