import Foundation
import NXPocketKit

/// The identifier a framework must be signed with: the app's own signature identifier, read from the running
/// executable's CodeDirectory. Under SideStore that is the bundle ID; under LiveContainer it is the host's.
public enum AppSignature {
    /// The running executable, read once: it cannot change while the app runs, and reading it means parsing the whole
    /// Mach-O, which the settings screen did on every redraw.
    private static let image: MachOFile? = Bundle.main.executablePath.flatMap {
        try? MachOFile.parse(contentsOf: URL(fileURLWithPath: $0))
    }
    private static let signature: CodeSignatureInfo? = image.flatMap { try? CodeSignatureInfo.read($0) }

    /// The entitlements the installer signed into the executable itself, which are what the system enforces.
    static let entitlements: [String: Any]? = image.flatMap(SignatureEntitlements.read)

    /// The same entitlements as the XML plist the installer wrote, byte for byte: what a game's signature copies
    /// when it is to agree with the app exactly (`DeviceSigner.Entitlements.appSigned`).
    static let entitlementsXML: Data? = image.flatMap(SignatureEntitlements.readXML)

    public static var currentIdentifier: String {
        guard let signature, !signature.identifier.isEmpty else {
            return Bundle.main.bundleIdentifier ?? "dev.nxpocketapple.app"
        }
        return signature.identifier
    }

    public static var currentTeam: String? { signature?.teamID }

    public static var description: String {
        let identifier = currentIdentifier
        let team = currentTeam.map { " · \($0)" } ?? ""
        return "\(identifier)\(team)"
    }
}

/// The entitlements blob of a signature (`CSMAGIC_EMBEDDED_ENTITLEMENTS`, an XML plist), read from the superblob.
enum SignatureEntitlements {
    static let superBlobMagic: UInt32 = 0xfade_0cc0
    static let entitlementsMagic: UInt32 = 0xfade_7171

    static func read(_ image: MachOFile) -> [String: Any]? {
        readXML(image).flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }
    }

    /// The XML plist of the entitlements blob, as it lies in the signature.
    static func readXML(_ image: MachOFile) -> Data? {
        guard let location = image.codeSignature else { return nil }
        let data = image.data
        let base = Int(location.offset), size = Int(location.size)
        guard base > 0, size >= 12, base + size <= data.count, be32(data, base) == superBlobMagic else { return nil }
        let count = Int(be32(data, base + 8))
        for index in 0..<min(count, 64) {
            let entry = base + 12 + index * 8
            guard entry + 8 <= base + size else { break }
            let offset = Int(be32(data, entry + 4))
            guard offset + 8 <= size else { continue }
            let blob = base + offset
            let length = Int(be32(data, blob + 4))
            guard be32(data, blob) == entitlementsMagic, length > 8, offset + length <= size else { continue }
            return data.subdata(in: (data.startIndex + blob + 8)..<(data.startIndex + blob + length))
        }
        return nil
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}

/// What this copy of the app was signed with: its bundle ID, the profile the installer embedded (application
/// identifier, keychain groups, team) and the entitlements in the executable's own signature. A keychain write refused
/// with -34018 (`errSecMissingEntitlement`) is explained here, and the Mac cannot read it off the phone. Nothing secret
/// is in it: no certificate, no key, no password.
public struct SigningFacts: Equatable, Sendable {
    public var bundleID: String
    public var signatureIdentifier: String?
    public var signatureTeam: String?
    public var profileName: String?
    public var profileExpires: Date?
    public var profileTeams: [String] = []
    public var profileApplicationIdentifier: String?
    public var profileKeychainGroups: [String] = []
    /// What kind of profile the installer used (development, ad hoc, enterprise or App Store): the stores that sign
    /// with a shared certificate differ here, and it decides what the system lets a loaded library claim.
    public var profileKind: String?
    /// How many entitlements the profile grants and how many the executable's own signature carries.
    public var profileEntitlementCount: Int?
    public var signedEntitlementCount: Int?
    /// Nil when the executable's signature carries no entitlements at all.
    public var signedApplicationIdentifier: String?
    public var signedKeychainGroups: [String]?

    public static let current = make(bundleID: Bundle.main.bundleIdentifier ?? "unknown",
                                     signatureIdentifier: AppSignature.currentIdentifier,
                                     signatureTeam: AppSignature.currentTeam,
                                     profile: ProvisioningProfile.dictionary(),
                                     signed: AppSignature.entitlements)

    static func make(bundleID: String, signatureIdentifier: String?, signatureTeam: String?,
                     profile: [String: Any]?, signed: [String: Any]?) -> SigningFacts {
        let granted = profile?["Entitlements"] as? [String: Any]
        var facts = SigningFacts(bundleID: bundleID, signatureIdentifier: signatureIdentifier, signatureTeam: signatureTeam)
        facts.profileName = profile?["Name"] as? String
        facts.profileExpires = profile?["ExpirationDate"] as? Date
        facts.profileTeams = profile?["TeamIdentifier"] as? [String] ?? []
        facts.profileApplicationIdentifier = granted?["application-identifier"] as? String
        facts.profileKeychainGroups = granted?["keychain-access-groups"] as? [String] ?? []
        facts.profileKind = profile.map { ProvisioningProfile.kind(of: $0) }
        facts.profileEntitlementCount = granted?.count
        facts.signedEntitlementCount = signed?.count
        if let signed {
            facts.signedApplicationIdentifier = signed["application-identifier"] as? String
            facts.signedKeychainGroups = signed["keychain-access-groups"] as? [String] ?? []
        }
        return facts
    }

    /// One fact per line, for an error and for a report.
    public var lines: [String] {
        func list(_ values: [String]) -> String { values.isEmpty ? "none" : values.joined(separator: ", ") }
        var lines = ["bundle ID: \(bundleID)",
                     "signature: \(signatureIdentifier ?? "none")\(signatureTeam.map { ", team \($0)" } ?? "")"]
        if let profileName {
            let expiry = profileExpires.map { ", expires \($0.formatted(.iso8601))" } ?? ""
            lines.append("profile: \(profileName)\(expiry), team \(list(profileTeams))")
            if let profileKind { lines.append("profile kind: \(profileKind)") }
            lines.append("profile application-identifier: \(profileApplicationIdentifier ?? "none")")
            lines.append("profile keychain-access-groups: \(list(profileKeychainGroups))")
        } else {
            lines.append("profile: no embedded.mobileprovision")
        }
        if let signedKeychainGroups {
            lines.append("signed application-identifier: \(signedApplicationIdentifier ?? "none")")
            if let signedEntitlementCount, let profileEntitlementCount {
                lines.append("entitlements: \(signedEntitlementCount) signed in the app, \(profileEntitlementCount) granted by its profile")
            }
            lines.append("signed keychain-access-groups: \(list(signedKeychainGroups))")
        } else {
            lines.append("signed entitlements: none")
        }
        return lines
    }
}

/// A keychain write the system refused, with its status. -34018 is `errSecMissingEntitlement`: the signature the
/// installer gave the app opens it no keychain group.
public struct KeychainRefusal: Error, Equatable {
    public static let missingEntitlement: OSStatus = -34018
    public var status: OSStatus
    public var account: String
}
