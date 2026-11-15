import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The code a player types once, and the proofs both sides exchange so that neither the code nor a token ever has to be
/// believed on the word of whoever answers.
///
/// ```
/// K     = PBKDF2-HMAC-SHA256(code, salt = "NXPocketApple pairing 1" ‖ pin, 600 000 rounds)
/// phone → { name, nonce, HMAC(K, "c" ‖ pin ‖ nonce ‖ name) }
/// Mac   → { token, HMAC(K, "s" ‖ pin ‖ nonce ‖ token) }     only when the phone's proof checks
/// ```
///
/// `pin` is the hash of the public key each side saw in its own TLS handshake. A relay with its own certificate makes
/// the phone's pin differ from the real Mac's, so the real Mac refuses the phone's proof; and the relay cannot make the
/// Mac's proof for the phone without the code. The code never goes on the wire.
public enum PairingProof {
    /// Six digits: short enough to read off the Mac and type on the iPhone in a breath. That is about 20 bits, so what protects it
    /// is not its size: it is worth three tries and two minutes (`PairingSessions`), it is never on the wire, and the key each
    /// side shows is what the player compares. The derivation is made slow on purpose (600 000 rounds, about half a second on
    /// a phone), so a relay that captured one exchange cannot try the million codes inside those two minutes.
    static let alphabet = Array("0123456789")
    public static let codeLength = 6
    public static let rounds: UInt32 = 600_000
    public static let maxNameLength = 64

    /// From the system's generator, shown as `123-456`.
    public static func makeCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<codeLength).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return String(characters[0..<3]) + "-" + String(characters[3...])
    }

    /// The code as typed, forgiven what a person gets wrong (a dash or a space, an O for a zero, an I or L for a one), or nil when it is not a code.
    public static func normalise(_ typed: String) -> String? {
        let mapped = typed.uppercased().unicodeScalars.compactMap { scalar -> Character? in
            switch scalar {
            case "-", " ", "\u{2010}", "\u{2011}", "\u{2013}": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return Character(scalar)
            }
        }
        guard mapped.count == codeLength, mapped.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return String(mapped)
    }

    public static func nonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return FileDigest.hex((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public static func key(code: String, pin: String) -> SymmetricKey? {
        guard let code = normalise(code) else { return nil }
        let salt = Array(("NXPocketApple pairing 1" + pin).utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = Array(code.utf8).withUnsafeBufferPointer { password in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(password.baseAddress!).assumingMemoryBound(to: Int8.self),
                                 password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                 &derived, derived.count)
        }
        return status == kCCSuccess ? SymmetricKey(data: derived) : nil
    }

    // MARK: QR code

    /// A secret as long as a key: what the QR code carries. The code is short and needs a slow derivation; this is not, so
    /// it needs none.
    public static func makeSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return FileDigest.hex((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public static func isSecret(_ text: String) -> Bool { text.count == 32 && text.allSatisfy(\.isHexDigit) }

    /// The same kind of key as `key(code:pin:)`, from the QR code's secret: bound to the pin the QR code names, so a phone
    /// that scanned it and a Mac that showed it end up with the key only if they mean the same server.
    public static func key(secret: String, pin: String) -> SymmetricKey? {
        guard isSecret(secret.lowercased()), let bytes = hexBytes(secret.lowercased()) else { return nil }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: Data(pin.utf8),
                                      info: Data("NXPocketApple pairing qr 1".utf8), outputByteCount: 32)
    }

    // MARK: number to compare

    /// The phone's promise of its nonce, sent before it has seen the Mac's: neither side can pick its nonce after the other's,
    /// so a relay cannot steer the two numbers to the same value.
    public static func commit(nonce: String, name: String) -> String {
        FileDigest.hex(SHA256.hash(data: framed("m", "commit", nonce, name)))
    }

    /// Six digits both screens show, from the key each side saw in its own handshake and both nonces. A relay between
    /// the two has a different key on each side, so the two numbers differ, and it cannot choose them to be equal.
    public static func number(pin: String, phoneNonce: String, macNonce: String) -> String {
        let digest = Array(SHA256.hash(data: framed("n", pin, phoneNonce, macNonce)))
        let value = digest[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let text = String(format: "%06u", value)
        return String(text.prefix(3)) + " " + String(text.suffix(3))
    }

    public static func clientProof(key: SymmetricKey, pin: String, nonce: String, name: String) -> String {
        mac(key, "c", pin, nonce, name)
    }

    public static func serverProof(key: SymmetricKey, pin: String, nonce: String, token: String) -> String {
        mac(key, "s", pin, nonce, token)
    }

    /// Constant-time: a proof is compared by a MAC check, not by `==`.
    public static func isValid(_ proof: String, key: SymmetricKey, role: String, pin: String, nonce: String, subject: String) -> Bool {
        guard let bytes = hexBytes(proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: framed(role, pin, nonce, subject), using: key)
    }

    private static func mac(_ key: SymmetricKey, _ role: String, _ fields: String...) -> String {
        FileDigest.hex(HMAC<SHA256>.authenticationCode(for: framed(role, fields[0], fields[1], fields[2]), using: key))
    }

    /// Each field is length-prefixed, so no two different messages share the same bytes.
    private static func framed(_ role: String, _ pin: String, _ nonce: String, _ subject: String) -> Data {
        var data = Data()
        for field in [role, pin, nonce, subject] {
            let bytes = Array(field.utf8)
            data.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Array($0) })
            data.append(contentsOf: bytes)
        }
        return data
    }

    static func hexBytes(_ text: String) -> Data? {
        guard text.count % 2 == 0, text.count <= 128 else { return nil }
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// The pin: the SHA-256 of a public key, not of a certificate, so the Mac can renew its certificate and keep every pairing.
public enum TLSPin {
    public static func fingerprint(of key: SecKey) -> String? {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else { return nil }
        return FileDigest.sha256(of: data)
    }

    public static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf) else { return nil }
        return fingerprint(of: key)
    }

    /// Eight groups of four, for a person to compare: `9f3a-77c1-…`.
    public static func display(_ pin: String) -> String {
        stride(from: 0, to: min(pin.count, 32), by: 4).map { start in
            let from = pin.index(pin.startIndex, offsetBy: start)
            return String(pin[from..<pin.index(from, offsetBy: 4)])
        }.joined(separator: "-")
    }
}
