import CryptoKit
import Foundation
import NXPocketKit

/// Which entitlements a game's signature copies. iOS accepts code outside the bundle only when the loaded image
/// agrees with the app about which app it belongs to (`docs/SIGNING.md`, probe 5C), and there are two places to copy
/// that from.
public enum EntitlementsChoice: String, Sendable, CaseIterable {
    /// The provisioning profile's `Entitlements`. This is what probe 5C signed with, and what works under SideStore,
    /// whose profile and whose signature agree.
    case profile
    /// The entitlements the installer signed into the running app itself, byte for byte. A store that signs with a
    /// shared or wildcard profile, or that trims what the app carries, leaves the profile and the app disagreeing:
    /// copying the app is agreement by construction.
    case app

    public var tag: String { rawValue }
}

/// What the app tries first, and what it tries when iOS refuses the first choice.
///
/// The profile's entitlements are the proven choice under SideStore, so they stay the default. When dyld refuses a
/// game and the app's own signature holds something different, the game is signed again with the app's and loaded
/// once more; the choice that worked is kept, per installation, so every game is signed that way from then on.
public enum SigningPreference {
    private static let key = "nxpocketapple.signing.entitlements"

    /// Changes with whatever installed the app: another store, a new profile, another team. A choice made for one
    /// installation says nothing about the next, so it is only trusted for the very signature it was made under.
    public static func fingerprint(identifier: String, team: String?, signedXML: Data?) -> String {
        let signed = signedXML.map { FileDigest.sha256(of: $0) } ?? "none"
        return FileDigest.sha256(of: Data("\(identifier)|\(team ?? "")|\(signed)".utf8))
    }

    /// Whether the app's signature and its profile disagree about the entitlements: only then is there a second
    /// choice worth a re-signing.
    static func differ(signed: [String: Any]?, profile: [String: Any]?) -> Bool {
        guard let signed, let profile else { return false }
        return !NSDictionary(dictionary: signed).isEqual(to: profile)
    }

    private static func stored(_ defaults: UserDefaults, fingerprint: String) -> [String: Any]? {
        guard let stored = defaults.dictionary(forKey: key), stored["fingerprint"] as? String == fingerprint else { return nil }
        return stored
    }

    public static func choice(signedAvailable: Bool, fingerprint: String, defaults: UserDefaults = .standard) -> EntitlementsChoice {
        guard signedAvailable, let stored = stored(defaults, fingerprint: fingerprint),
              let raw = stored["choice"] as? String, let choice = EntitlementsChoice(rawValue: raw) else { return .profile }
        return choice
    }

    /// Both choices were tried on this installation and dyld refused both: nothing more to switch to, so a refused
    /// game is not signed again and again at every tap.
    public static func isExhausted(fingerprint: String, defaults: UserDefaults = .standard) -> Bool {
        stored(defaults, fingerprint: fingerprint)?["exhausted"] as? Bool ?? false
    }

    /// The other choice, when the two sources differ and it has not been tried; nil when trying it could change
    /// nothing.
    public static func alternative(to choice: EntitlementsChoice, signed: [String: Any]?, profile: [String: Any]?,
                                   exhausted: Bool = false) -> EntitlementsChoice? {
        guard !exhausted, differ(signed: signed, profile: profile) else { return nil }
        return choice == .profile ? .app : .profile
    }

    public static func remember(_ choice: EntitlementsChoice, fingerprint: String, exhausted: Bool = false,
                                defaults: UserDefaults = .standard) {
        defaults.set(["choice": choice.rawValue, "fingerprint": fingerprint, "exhausted": exhausted], forKey: key)
    }

    public static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    // MARK: - This installation

    public static var currentFingerprint: String {
        fingerprint(identifier: AppSignature.currentIdentifier, team: AppSignature.currentTeam, signedXML: AppSignature.entitlementsXML)
    }

    public static var current: EntitlementsChoice {
        choice(signedAvailable: AppSignature.entitlementsXML != nil, fingerprint: currentFingerprint)
    }

    public static var currentAlternative: EntitlementsChoice? {
        alternative(to: current, signed: AppSignature.entitlements,
                    profile: ProvisioningProfile.dictionary()?["Entitlements"] as? [String: Any],
                    exhausted: isExhausted(fingerprint: currentFingerprint))
    }

    public static func remember(_ choice: EntitlementsChoice, exhausted: Bool = false) {
        remember(choice, fingerprint: currentFingerprint, exhausted: exhausted)
    }
}

/// What a game's signature says, read back from the Mach-O the app signed.
public struct GameSignatureFacts: Sendable {
    public var identifier: String
    public var teamID: String?
    public var hasCertificate: Bool
    public var signerName: String?
    public var applicationIdentifier: String?
    /// The entitlement keys the signature carries; nil when it has no entitlements blob at all.
    public var entitlementKeys: [String]?

    public static func read(executable: URL) -> GameSignatureFacts? {
        guard let image = try? MachOFile.parse(contentsOf: executable),
              let signature = try? CodeSignatureInfo.read(image) else { return nil }
        let entitlements = SignatureEntitlements.read(image)
        return GameSignatureFacts(identifier: signature.identifier, teamID: signature.teamID,
                                  hasCertificate: signature.hasCertificate, signerName: signature.signerName,
                                  applicationIdentifier: entitlements?["application-identifier"] as? String,
                                  entitlementKeys: entitlements.map { $0.keys.sorted() })
    }
}

/// Why iOS may have refused a game's code, worked out from what the app and the game's signature say. dyld's own
/// words ("file system sandbox blocked mmap()") name no cause; each verdict below is a difference a person can fix.
public struct SigningDiagnosis: Equatable, Sendable {
    public enum Verdict: String, Sendable {
        /// The certificate imported is not one the app's profile lists: another certificate than the one that
        /// installed the app.
        case certificateNotInProfile
        /// The certificate belongs to a team other than the one that installed the app.
        case teamMismatch
        /// The game was signed under another identifier than the app's own.
        case identifierMismatch
        /// The game claims another application-identifier than the app's signature.
        case applicationIdentifierMismatch
        /// The game claims entitlements the app's own signature does not carry.
        case entitlementsDiffer
        /// Everything the app can compare agrees, and the app is signed for distribution (no `get-task-allow`: an ad hoc,
        /// enterprise or App Store profile). The setup measured to load games outside the bundle is a development
        /// signature (probe 5C, SideStore), and measured on a FlareStore install with an ad hoc profile, where the
        /// certificate, team, identifier and all 41 entitlements agreed, dyld still refused. Not proven to be the cause.
        case distributionProfile
        /// dyld said the *sandbox* denied mapping the game's code (`file-map-executable`), on an app signed for
        /// development: not a signature problem, whatever the signature looks like. The cause is in what the app's own
        /// process is allowed, which the app cannot read from inside.
        case sandboxDenied
        /// Everything the app can check agrees: the cause is not one it can see from inside.
        case nothingFound
    }

    public var verdict: Verdict
    public var lines: [String]

    /// Whether the app was signed for distribution: its own signature does not carry `get-task-allow`. Nil answer for
    /// "cannot tell" is false: nothing is claimed about a signature that could not be read.
    public static func isDistributionSigned(_ signed: [String: Any]?) -> Bool {
        guard let signed else { return false }
        return signed["get-task-allow"] as? Bool != true
    }

    /// Inputs are plain values so the whole decision is testable without a device.
    public static func make(appIdentifier: String, appTeam: String?, appSigned: [String: Any]?,
                            profileTeams: [String], profileCertificateHashes: Set<String>?,
                            certificateSHA256: String?, certificateTeam: String?,
                            game: GameSignatureFacts?, profileKind: String? = nil,
                            choice: EntitlementsChoice? = nil, sandboxDenial: Bool = false) -> SigningDiagnosis {
        var lines: [String] = []
        let appApplicationIdentifier = appSigned?["application-identifier"] as? String
        lines.append("app: signed as \(appIdentifier), team \(appTeam ?? "none"), "
                     + "application-identifier \(appApplicationIdentifier ?? "none")"
                     + (profileKind.map { ", profile \($0)" } ?? ""))

        var verdict = Verdict.nothingFound

        if let certificateSHA256, let hashes = profileCertificateHashes {
            let listed = hashes.contains(certificateSHA256.lowercased()) || hashes.contains(certificateSHA256.uppercased())
            lines.append("certificate: \(listed ? "listed in" : "NOT in") the app's profile")
            if !listed { verdict = .certificateNotInProfile }
        }
        if let certificateTeam {
            let appTeams = Set(([appTeam].compactMap { $0 }) + profileTeams)
            let matches = appTeams.isEmpty || appTeams.contains(certificateTeam)
            lines.append("certificate team \(certificateTeam): \(matches ? "same as the app's" : "DIFFERENT from the app's \(appTeams.sorted().joined(separator: ", "))")")
            if !matches, verdict == .nothingFound { verdict = .teamMismatch }
        }

        if let game {
            lines.append("game: signed as \(game.identifier), team \(game.teamID ?? "none"), "
                         + "application-identifier \(game.applicationIdentifier ?? "none"), "
                         + "\(game.entitlementKeys?.count ?? 0) entitlements"
                         + (choice.map { ", copied from the \($0 == .app ? "app's signature" : "profile")" } ?? ""))
            if game.identifier != appIdentifier {
                lines.append("the game's identifier is not the app's")
                if verdict == .nothingFound { verdict = .identifierMismatch }
            }
            if let appApplicationIdentifier, game.applicationIdentifier != appApplicationIdentifier {
                lines.append("the game's application-identifier is not the app's")
                if verdict == .nothingFound { verdict = .applicationIdentifierMismatch }
            }
            let own = Set(appSigned?.keys.map { $0 } ?? [])
            let extra = Set(game.entitlementKeys ?? []).subtracting(own).sorted()
            if !extra.isEmpty {
                let shown = extra.prefix(6).joined(separator: ", ") + (extra.count > 6 ? ", …" : "")
                lines.append("the game claims \(extra.count) entitlements the app's own signature lacks: \(shown)")
                if verdict == .nothingFound { verdict = .entitlementsDiffer }
            }
        } else {
            lines.append("game: its signature could not be read")
        }
        if sandboxDenial {
            // dyld has two messages for a refused mapping: "code signing blocked mmap()" and "file system sandbox blocked
            // mmap()" (both are in the iPhone's own dyld). The second means the sandbox policy of this process denies
            // executing code from this path, before the signature is ever judged: the comparisons above can all be right
            // and the game still refused, and signing it differently cannot change that.
            lines.append("dyld names the file system sandbox, not code signing: how the game is signed is not what refused it")
            verdict = isDistributionSigned(appSigned) ? .distributionProfile : .sandboxDenied
            if verdict == .distributionProfile {
                lines.append("the app is signed for distribution (get-task-allow is not set): iOS most likely only lets a development-signed app run code from outside its bundle")
            }
        } else if verdict == .nothingFound, isDistributionSigned(appSigned) {
            lines.append("the app is signed for distribution (get-task-allow is not set): iOS most likely does not let it run code from outside its bundle")
            verdict = .distributionProfile
        }
        return SigningDiagnosis(verdict: verdict, lines: lines)
    }
}
