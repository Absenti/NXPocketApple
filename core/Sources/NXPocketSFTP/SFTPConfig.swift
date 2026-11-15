import Foundation

/// A server the player added: where it is, who logs in, which of its keys is trusted, and the folder that holds the
/// `<title ID>.nxgame` folders. What proves the player to the server is not here: it is the `SFTPCredential`, kept in the keychain.
public struct SFTPConfig: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    /// SHA-256 of the server's host key (the blob OpenSSH fingerprints), as hex, fixed when the player accepted it.
    public var hostKey: String?
    public var folder: String

    public static let defaultPort = 22

    public init(host: String, port: Int = SFTPConfig.defaultPort, user: String, hostKey: String? = nil, folder: String = "/") {
        self.host = host
        self.port = port
        self.user = user
        self.hostKey = hostKey
        self.folder = folder
    }
}

/// What the server is shown to let the player in: a password, or an ed25519 key in OpenSSH's format (with its passphrase when
/// it has one). It is one string in the keychain, never a file.
public struct SFTPCredential: Codable, Equatable, Sendable {
    public var password: String?
    public var privateKey: String?
    public var passphrase: String?

    public init(password: String? = nil, privateKey: String? = nil, passphrase: String? = nil) {
        self.password = password
        self.privateKey = privateKey
        self.passphrase = passphrase
    }

    public var secret: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    public static func decode(_ secret: String) -> SFTPCredential? {
        guard let data = secret.data(using: .utf8), let value = try? JSONDecoder().decode(SFTPCredential.self, from: data),
              value.password != nil || value.privateKey != nil else { return nil }
        return value
    }
}

/// The key a server presented, for the player to accept before anything secret is sent.
public struct SFTPHostKey: Equatable, Sendable {
    /// SHA-256 of the key's wire blob, as hex: what `SFTPConfig.hostKey` holds.
    public var pin: String
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, …
    public var type: String

    public init(pin: String, type: String) {
        self.pin = pin
        self.type = type
    }

    /// `SHA256:` and the unpadded base64, as OpenSSH and every SFTP client print it, so the player can compare it with what
    /// the server's own tools show (`ssh-keygen -lf`).
    public var display: String {
        var bytes = Data()
        var index = pin.startIndex
        while index < pin.endIndex, let next = pin.index(index, offsetBy: 2, limitedBy: pin.endIndex) {
            if let byte = UInt8(pin[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return "SHA256:" + bytes.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}
