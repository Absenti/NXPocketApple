import Foundation

/// Pairing by comparing a number, for when the QR code cannot be scanned: the phone and the Mac each show six digits, and
/// the player allows the pairing on the Mac only if they read the same (`PairingProof.number`).
///
/// ```
/// phone → Mac   request  { name, commit = H(nonceP ‖ name) }      → { nonce = nonceM }
/// phone → Mac   reveal   { commit, nonce = nonceP }               (the Mac checks the promise; both show the number)
/// phone → Mac   confirm  { commit }, until the Mac answers        → { token }  once the player allowed it
/// ```
///
/// The phone is not asked to trust anything it has not compared: it sends `confirm` only after the player said the numbers
/// match, and the Mac answers it with a token only after the player allowed it there.
public final class NumberPairing: @unchecked Sendable {
    public let host: String
    public let port: Int
    public let pin: String
    public let macName: String
    /// `482 913`, to show next to the one on the Mac.
    public let number: String
    private let commit: String
    private let deviceName: String
    private let session: HTTPSession

    private init(host: String, port: Int, pin: String, macName: String, number: String, commit: String, deviceName: String, session: HTTPSession) {
        self.host = host
        self.port = port
        self.pin = pin
        self.macName = macName
        self.number = number
        self.commit = commit
        self.deviceName = deviceName
        self.session = session
    }

    deinit { session.invalidate() }

    /// Asks the Mac at `host:port` to pair, and returns once both sides have the number. Throws `PairingError.refused` when
    /// the Mac is not showing a pairing window.
    public static func begin(host: String, port: Int, deviceName: String) async throws -> NumberPairing {
        let name = RemoteListing.text(deviceName, limit: PairingProof.maxNameLength)
        let (pin, macName) = try await PinnedHTTPSSource.hello(host: host, port: port)
        let session = HTTPSession(trust: .pinned(pin))
        do {
            let phoneNonce = PairingProof.nonce()
            let commit = PairingProof.commit(nonce: phoneNonce, name: name)
            let (status, body) = try await PinnedHTTPSSource.post(session, host: host, port: port, path: "pair/request",
                                                                   ["name": name, "commit": commit])
            try PinnedHTTPSSource.checkPairing(status)
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let macNonce = json["nonce"] as? String, macNonce.count == 32, macNonce.allSatisfy(\.isHexDigit) else {
                throw PairingError.wrongMac
            }
            let (revealed, _) = try await PinnedHTTPSSource.post(session, host: host, port: port, path: "pair/reveal",
                                                                  ["commit": commit, "nonce": phoneNonce])
            try PinnedHTTPSSource.checkPairing(revealed)
            return NumberPairing(host: host, port: port, pin: pin, macName: macName,
                                 number: PairingProof.number(pin: pin, phoneNonce: phoneNonce, macNonce: macNonce),
                                 commit: commit, deviceName: name, session: session)
        } catch {
            session.invalidate()
            throw error
        }
    }

    /// The player says the numbers match: waits for the Mac's answer, up to `timeout`, and returns what it issued.
    public func confirm(timeout: TimeInterval = PairingWait.limit, interval: TimeInterval = 1) async throws -> PairedMac {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let (status, body) = try await PinnedHTTPSSource.post(session, host: host, port: port, path: "pair/confirm", ["commit": commit])
            try PinnedHTTPSSource.checkPairing(status)
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if json["state"] as? String == "approved", let token = json["token"] as? String, token.count == 64, FileDigest.isSHA256(token) {
                    return PairedMac(host: host, port: port, pin: pin, token: token,
                                     name: (json["name"] as? String).map { RemoteListing.text($0, limit: 64) } ?? macName)
                }
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw PairingError.refused
    }

    /// The numbers differ, or the player gave up: the Mac drops the request.
    public func cancel() async {
        _ = try? await PinnedHTTPSSource.post(session, host: host, port: port, path: "pair/cancel", ["commit": commit])
    }
}

public enum PairingWait {
    /// The Mac's window is two minutes; a little more is never useful.
    public static let limit: TimeInterval = 125
}
