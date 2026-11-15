import Foundation
import NXPocketKit
import Security

/// The key the launcher's server proves itself with, and the self-signed certificate TLS needs around it.
///
/// The key is a file (mode 0600, in a folder of mode 0700, kept out of backups), not a Keychain item: the launcher is ad
/// hoc signed, its identity changes with each update, and the Keychain would ask the player for a password again, out of
/// context. The phone pins the key's hash, so the certificate is rebuilt at every start and nothing about it matters
/// (its names, its dates): only the key does.
public struct ServerIdentity: @unchecked Sendable {
    public let key: SecKey
    public let certificate: SecCertificate
    public let identity: SecIdentity
    /// SHA-256 of the public key: what a phone pins and the pairing proofs are bound to.
    public let pin: String

    public static var standardFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NXPocketApple/Sharing", isDirectory: true)
    }

    static let keyFile = "server-key.bin"

    /// Loads the key in `folder`, or makes one. A key file that cannot be read back is replaced: every phone then has to
    /// pair again, which is what a lost key means.
    public static func load(from folder: URL = standardFolder, fileManager: FileManager = .default) throws -> ServerIdentity {
        try prepare(folder, fileManager: fileManager)
        let url = folder.appendingPathComponent(keyFile)
        if let data = BoundedRead.dataIfPresent(at: url, limit: 4096), let key = importKey(data) {
            return try ServerIdentity(key: key)
        }
        return try create(in: folder, fileManager: fileManager)
    }

    /// A new key: every phone paired with the old one is no longer recognised.
    public static func reset(in folder: URL = standardFolder, fileManager: FileManager = .default) throws -> ServerIdentity {
        try prepare(folder, fileManager: fileManager)
        return try create(in: folder, fileManager: fileManager)
    }

    private static func prepare(_ folder: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = folder
        try? mutable.setResourceValues(values)
    }

    private static func create(in folder: URL, fileManager: FileManager) throws -> ServerIdentity {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                         kSecAttrKeySizeInBits as String: 256, kSecAttrIsPermanent as String: false]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw NXPocketError(.signingFailed, "the sharing key could not be made: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        let url = folder.appendingPathComponent(keyFile)
        // Written with its final mode from the start: a file made world-readable and then restricted has been readable.
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else {
            throw NXPocketError(.transferFailed, "the sharing key could not be saved: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw NXPocketError(.transferFailed, "the sharing key could not be saved") }
        return try ServerIdentity(key: key)
    }

    static func importKey(_ data: Data) -> SecKey? {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }

    init(key: SecKey) throws {
        guard let publicKey = SecKeyCopyPublicKey(key), let pin = TLSPin.fingerprint(of: publicKey) else {
            throw NXPocketError(.signingFailed, "the sharing key has no public half")
        }
        let der = try Self.selfSignedCertificate(key: key, publicKey: publicKey)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let identity = SecIdentityCreate(nil, certificate, key) else {
            throw NXPocketError(.signingFailed, "the sharing certificate was refused by the system")
        }
        self.key = key
        self.certificate = certificate
        self.identity = identity
        self.pin = pin
    }

    // MARK: a self-signed certificate, by hand

    // Security.framework signs and verifies but cannot make a certificate without a keychain, so the few DER structures
    // an X.509 v3 certificate needs are written here: ECDSA P-256 with SHA-256, a common name, five years of validity.

    static func selfSignedCertificate(key: SecKey, publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw NXPocketError(.signingFailed, "the public key could not be exported")
        }
        let signatureAlgorithm = sequence(oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))
        let name = sequence(set(sequence(oid([0x55, 0x04, 0x03]), der(0x0c, Array("NXPocketApple".utf8)))))
        let serial = (0..<16).map { _ in UInt8.random(in: 1...255) }
        let now = Date()
        let tbs = sequence(
            der(0xa0, integer([2])),
            integer(serial),
            signatureAlgorithm,
            name,
            sequence(utcTime(now.addingTimeInterval(-3600)), utcTime(now.addingTimeInterval(5 * 365 * 86400))),
            name,
            sequence(sequence(oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]), oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])),
                     bitString([UInt8](point)))
        )
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) as Data? else {
            throw NXPocketError(.signingFailed, "the certificate could not be signed")
        }
        return Data(sequence(tbs, signatureAlgorithm, bitString([UInt8](signature))))
    }

    private static func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if body.count < 128 { out.append(UInt8(body.count)) }
        else if body.count < 256 { out += [0x81, UInt8(body.count)] }
        else { out += [0x82, UInt8(body.count >> 8), UInt8(body.count & 0xff)] }
        return out + body
    }
    private static func oid(_ bytes: [UInt8]) -> [UInt8] { der(0x06, bytes) }
    private static func sequence(_ parts: [UInt8]...) -> [UInt8] { der(0x30, parts.flatMap { $0 }) }
    private static func set(_ parts: [UInt8]...) -> [UInt8] { der(0x31, parts.flatMap { $0 }) }
    private static func integer(_ value: [UInt8]) -> [UInt8] {
        var bytes = Array(value.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return der(0x02, bytes)
    }
    private static func bitString(_ bytes: [UInt8]) -> [UInt8] { der(0x03, [0] + bytes) }
    private static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return der(0x17, Array(formatter.string(from: date).utf8))
    }
}
