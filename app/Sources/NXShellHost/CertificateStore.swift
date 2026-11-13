import CryptoKit
import Foundation
import NXPocketKit
import Security

#if canImport(NXZSign)
import NXZSign
#endif

/// What the app knows about the certificate that signs its games. Held in the keychain, never on disk.
public struct StoredCertificate: Equatable, Sendable {
    public var subject: String
    public var teamID: String
    public var expires: Date
    /// SHA-256 of the DER certificate: what a game's `.signing.json` records, so a renewal is spotted.
    public var sha256: String

    public init(subject: String, teamID: String, expires: Date, sha256: String) {
        self.subject = subject
        self.teamID = teamID
        self.expires = expires
        self.sha256 = sha256
    }

    public var isExpired: Bool { expires <= Date() }
    public var daysLeft: Int { Int(expires.timeIntervalSinceNow / 86400) }
}

/// Imports a `.p12` exported from SideStore, keeps it in the keychain, and turns it into the identity a framework
/// is signed with.
public enum CertificateImporter {
    public struct Imported {
        public var certificate: StoredCertificate
        public var p12: Data
        public var passphrase: String
    }

    /// Reads the certificate with the parser that will sign with it. On a build with the signing engine that is
    /// zsign's OpenSSL: iOS's SecPKCS12Import refused a SideStore export (errSecDecode, -26275) that zsign opens and
    /// signs with, so accepting or refusing a `.p12` by Security's verdict would be checking the wrong thing.
    public static func read(p12: Data, passphrase: String) throws -> Imported {
        #if canImport(NXZSign)
        return try readWithSigningEngine(p12: p12, passphrase: passphrase)
        #else
        return try readWithSecurity(p12: p12, passphrase: passphrase)
        #endif
    }

    #if canImport(NXZSign)
    static func readWithSigningEngine(p12: Data, passphrase: String) throws -> Imported {
        var der = [UInt8](repeating: 0, count: 16 * 1024)
        var length: Int32 = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = p12.withUnsafeBytes { bytes in
            nxpocket_p12_certificate(bytes.bindMemory(to: UInt8.self).baseAddress, Int32(p12.count), passphrase,
                                     &der, Int32(der.count), &length, &error, Int32(error.count))
        }
        switch status {
        case 0:
            break
        case NXPOCKET_P12_WRONG_PASSWORD:
            throw NXPocketError(.noCertificate, "that password does not open this .p12")
        case NXPOCKET_P12_NO_CERTIFICATE:
            throw NXPocketError(.noCertificate, "the .p12 holds no identity")
        default:
            throw NXPocketError(.noCertificate, "the .p12 could not be read: \(String(cString: error))")
        }
        guard let certificate = SecCertificateCreateWithData(nil, Data(der.prefix(Int(length))) as CFData) else {
            throw NXPocketError(.noCertificate, "this certificate's encoding could not be read")
        }
        return Imported(certificate: try describe(certificate), p12: p12, passphrase: passphrase)
    }
    #endif

    /// Security's reader, for a build without the signing engine (which then cannot sign anyway).
    static func readWithSecurity(p12: Data, passphrase: String) throws -> Imported {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        let status = SecPKCS12Import(p12 as CFData, options, &items)
        guard status == errSecSuccess else {
            if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure {
                throw NXPocketError(.noCertificate, "that password does not open this .p12")
            }
            throw NXPocketError(.noCertificate, "the .p12 could not be read (status \(status))")
        }
        // Checked by its Core Foundation type: a CF object cannot be tested with `as?` (it always succeeds), and a
        // forced cast on what a user-chosen file decodes to would trap the app on a malformed .p12.
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityItem = first[kSecImportItemIdentity as String],
              CFGetTypeID(identityItem as CFTypeRef) == SecIdentityGetTypeID() else {
            throw NXPocketError(.noCertificate, "the .p12 holds no identity")
        }
        let identity = unsafeDowncast(identityItem as AnyObject, to: SecIdentity.self)
        var certificateRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificateRef) == errSecSuccess, let certificateRef else {
            throw NXPocketError(.noCertificate, "the .p12's identity has no certificate")
        }
        return Imported(certificate: try describe(certificateRef), p12: p12, passphrase: passphrase)
    }

    /// iOS has no public X.509 reader, so the DER is walked (`X509Certificate`); the Security summary is the
    /// fallback for a certificate whose encoding that walker does not understand.
    public static func describe(_ certificate: SecCertificate) throws -> StoredCertificate {
        let der = SecCertificateCopyData(certificate) as Data
        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "certificate"
        guard let parsed = X509Certificate.parse(der: der) else {
            throw NXPocketError(.noCertificate, "this certificate's encoding could not be read")
        }
        let subject = parsed.commonName.map { "\(summary) (\($0))" } ?? summary
        guard let team = parsed.organizationalUnit, !team.isEmpty else {
            throw NXPocketError(.teamMismatch, "this certificate names no team")
        }
        return StoredCertificate(subject: subject, teamID: team,
                                 expires: parsed.notAfter ?? .distantPast, sha256: parsed.sha256)
    }
}

/// The `.p12` and its password, out of the keychain only while a signature is being made.
public enum CertificateVault {
    /// Both in one keychain item, so a replacement can never leave a new .p12 beside the old password.
    public static func store(_ imported: CertificateImporter.Imported) throws {
        try Keychain.store(encode(p12: imported.p12, passphrase: imported.passphrase),
                           account: Keychain.identityAccount, service: .certificate)
        Keychain.remove(account: Keychain.p12Account, service: .certificate)
        Keychain.remove(account: Keychain.passphraseAccount, service: .certificate)
    }

    public static var isInstalled: Bool {
        Keychain.has(account: Keychain.identityAccount, service: .certificate)
            || Keychain.has(account: Keychain.p12Account, service: .certificate)
    }

    public static func credentials() -> (p12: Data, passphrase: String)? {
        if let data = Keychain.load(account: Keychain.identityAccount, service: .certificate) { return decode(data) }
        guard let p12 = Keychain.load(account: Keychain.p12Account, service: .certificate),
              let passphrase = Keychain.load(account: Keychain.passphraseAccount, service: .certificate) else { return nil }
        return (p12, String(decoding: passphrase, as: UTF8.self))
    }

    static func encode(p12: Data, passphrase: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["p12": p12, "passphrase": passphrase],
                                           format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> (p12: Data, passphrase: String)? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let p12 = object["p12"] as? Data, let passphrase = object["passphrase"] as? String else { return nil }
        return (p12, passphrase)
    }

    public static func remove() { Keychain.removeAll() }
}
