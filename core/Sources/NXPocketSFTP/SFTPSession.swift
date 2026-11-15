import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NXPocketKit

/// Decides about a server's key during the handshake, before a password or a key signature is sent: either it is the key the
/// player accepted, or the handshake stops, with the key it showed kept to be reported.
final class HostKeyJudge: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    enum Mode { case pinned(String), reveal }

    struct Refused: Error {}

    private let mode: Mode
    private let lock = NSLock()
    private var _seen: SFTPHostKey?
    private var _refused: SFTPHostKey?

    init(_ mode: Mode) { self.mode = mode }

    var seen: SFTPHostKey? { lock.withLock { _seen } }
    /// The key that was turned away, when one was: a key that was accepted and a login that failed after it are not this.
    var refused: SFTPHostKey? { lock.withLock { _refused } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // "ssh-ed25519 AAAA…": the second word is the key's wire blob, which is what a fingerprint is made of.
        let text = String(openSSHPublicKey: hostKey)
        let words = text.split(separator: " ")
        guard words.count >= 2, let blob = Data(base64Encoded: String(words[1])) else {
            validationCompletePromise.fail(Refused())
            return
        }
        let key = SFTPHostKey(pin: FileDigest.sha256(of: blob), type: String(words[0]))
        lock.withLock { _seen = key }
        switch mode {
        case .reveal:
            lock.withLock { _refused = key }
            validationCompletePromise.fail(Refused())
        case .pinned(let expected):
            if expected == key.pin {
                validationCompletePromise.succeed(())
            } else {
                lock.withLock { _refused = key }
                validationCompletePromise.fail(Refused())
            }
        }
    }
}

/// One SSH connection, and the SFTP channels opened on it. Connected when first needed, dropped on `close()`.
actor SFTPSession {
    let config: SFTPConfig
    private let credential: SFTPCredential
    private let timeout: TimeInterval
    private var group: MultiThreadedEventLoopGroup?
    private var client: SSHClient?

    init(config: SFTPConfig, credential: SFTPCredential, timeout: TimeInterval = SharingLimits.idleTimeout) {
        self.config = config
        self.credential = credential
        self.timeout = timeout
    }

    /// What the server's key is, without sending anything of the player's: the handshake is stopped at the key.
    static func hostKey(of config: SFTPConfig, timeout: TimeInterval = 10) async throws -> SFTPHostKey {
        let judge = HostKeyJudge(.reveal)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        do {
            let client = try await SSHClient.connect(host: config.host, port: config.port,
                                                     authenticationMethod: .passwordBased(username: config.user, password: ""),
                                                     hostKeyValidator: .custom(judge), reconnect: .never, group: group,
                                                     connectTimeout: .seconds(Int64(timeout)))
            try? await client.close()
        } catch {
            if let key = judge.seen { return key }
            throw SFTPErrors.map(error, judge: judge)
        }
        throw PackageSourceError.malformed("the server did not present a key")
    }

    func close() async {
        let client = self.client, group = self.group
        self.client = nil
        self.group = nil
        try? await client?.close()
        group?.shutdownGracefully { _ in }
    }

    private func connection() async throws -> SSHClient {
        if let client, client.isConnected { return client }
        await close()
        guard let pin = config.hostKey else { throw PackageSourceError.untrusted(fingerprint: "") }
        let judge = HostKeyJudge(.pinned(pin))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let authentication = try method()
            let connected = try await SSHClient.connect(host: config.host, port: config.port, authenticationMethod: authentication,
                                                        hostKeyValidator: .custom(judge), reconnect: .never, group: group,
                                                        connectTimeout: .seconds(10))
            self.client = connected
            self.group = group
            return connected
        } catch {
            group.shutdownGracefully { _ in }
            throw SFTPErrors.map(error, judge: judge)
        }
    }

    private func method() throws -> SSHAuthenticationMethod {
        if let key = credential.privateKey {
            do {
                let decryption = credential.passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
                return .ed25519(username: config.user, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: decryption))
            } catch {
                throw PackageSourceError.malformed("the private key could not be read: only ed25519 keys in OpenSSH format are supported")
            }
        }
        guard let password = credential.password else { throw PackageSourceError.unauthorized }
        return .passwordBased(username: config.user, password: password)
    }

    /// An SFTP channel for one job, closed when it is over. Directory handles of a channel go with it, which a long walk of
    /// a package would otherwise leave open on the server one by one.
    func withSFTP<T: Sendable>(_ body: @Sendable (SFTPClient) async throws -> T) async throws -> T {
        let ssh = try await connection()
        let sftp: SFTPClient
        do { sftp = try await Timeout.run(seconds: timeout, onTimeout: { Task { await self.close() } }) { try await ssh.openSFTP() } }
        catch { throw SFTPErrors.map(error, judge: nil) }
        do {
            let result = try await body(sftp)
            try? await sftp.close()
            return result
        } catch {
            try? await sftp.close()
            throw SFTPErrors.map(error, judge: nil)
        }
    }

    /// A channel that outlives the call: a download's. The caller closes it.
    func openChannel() async throws -> SFTPClient {
        let ssh = try await connection()
        do { return try await Timeout.run(seconds: timeout, onTimeout: { Task { await self.close() } }) { try await ssh.openSFTP() } }
        catch { throw SFTPErrors.map(error, judge: nil) }
    }
}

enum SFTPErrors {
    /// What went wrong, in the terms the screens already know: a refused login, a key that is not the accepted one, a server
    /// that is not there, a file that is not.
    static func map(_ error: Error, judge: HostKeyJudge?) -> Error {
        if error is PackageSourceError || error is NXPocketError { return error }
        if let refused = judge?.refused { return PackageSourceError.untrusted(fingerprint: refused.pin) }
        if let sshError = error as? SSHClientError, case .allAuthenticationOptionsFailed = sshError { return PackageSourceError.unauthorized }
        // A status the server answered with comes back either as the error itself or wrapped.
        if let status = error as? SFTPMessage.Status { return Self.answer(status) }
        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .errorStatus(let status): return Self.answer(status)
            case .connectionClosed: return PackageSourceError.unreachable("the connection was closed")
            default: return PackageSourceError.malformed("the server's SFTP answer was not understood")
            }
        }
        if error is CancellationError { return error }
        return PackageSourceError.unreachable(Self.describe(error))
    }

    static func answer(_ status: SFTPMessage.Status) -> Error {
        switch status.errorCode {
        case .noSuchFile: return PackageSourceError.notFound
        case .permissionDenied: return PackageSourceError.unreachable("the server refused access to this file")
        default: return PackageSourceError.unreachable("the server answered: \(status.message)")
        }
    }

    static func describe(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("Connection refused") || text.contains("connectionRefused") { return "the server refused the connection" }
        if text.contains("timeout") || text.contains("Timeout") { return "the server stopped answering" }
        if text.contains("noMatching") || text.contains("negotiat") {
            return "no cipher or key in common with the server (it needs aes-gcm, curve25519 and an ed25519 or ECDSA host key)"
        }
        return "could not connect to the server"
    }
}

/// An `await` that gives up, and stops waiting when its task is cancelled (a pause must not wait for a stalled server). The
/// work itself is not cancellable (it waits on the network), so on timeout or cancellation it is left behind, and on timeout
/// `onTimeout` closes the connection it waits on.
enum Timeout {
    static func run<T: Sendable>(seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void,
                                 _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let awaiter = Awaiter<T>()
        let job = Task {
            do { _ = awaiter.finish(.success(try await work())) } catch { _ = awaiter.finish(.failure(error)) }
        }
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            if awaiter.finish(.failure(PackageSourceError.unreachable("the server stopped answering"))) {
                onTimeout()
                job.cancel()
            }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { awaiter.install($0) }
        } onCancel: {
            if awaiter.finish(.failure(CancellationError())) { job.cancel() }
        }
    }
}

/// The one answer of a `Timeout.run`, from whichever of the work, the timer and the cancellation comes first.
final class Awaiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let ready = lock.withLock { () -> Result<T, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    /// True for the first call only, which is the one whose answer is used.
    func finish(_ answer: Result<T, Error>) -> Bool {
        let pending = lock.withLock { () -> (Bool, CheckedContinuation<T, Error>?) in
            guard !finished else { return (false, nil) }
            finished = true
            if let continuation { self.continuation = nil; return (true, continuation) }
            result = answer
            return (true, nil)
        }
        pending.1?.resume(with: answer)
        return pending.0
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}
