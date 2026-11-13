import Foundation
import NXPocketKit

#if canImport(NXZSign)
import NXZSign
#endif

/// Signs a framework on the device, the way LiveContainer does: with the user's own certificate, and with the
/// signature identifier of the app that will load it (see `NOTICE` and `docs/SIGNING.md`).
///
/// The signing engine is zsign, linked statically. `tools/build_zsign.sh` fetches the pinned revision, builds
/// `libnxzsign.a` from `tools/zsign_shim.cpp`, and turns this type on. Without it the app still imports games and
/// says why it cannot sign, instead of leaving a framework that iOS would refuse to load.
public struct DeviceSigner: FrameworkSigner {
    /// What a game's signature carries as entitlements.
    public enum Entitlements: Sendable, Equatable {
        /// An explicit empty dict. This is what probe tests 5A and 5B signed with, and iOS refused both outside the
        /// bundle (`code signature invalid`). Kept for the tests and for comparison, never for a game.
        case none
        /// The profile's own entitlements: what LiveContainer's re-signing amounts to, and exactly what probe test 5C
        /// signs with (an empty entitlements path, so zsign takes the profile's). The proven choice under SideStore.
        case appProfile
        /// The entitlements the installer signed into the running app, copied byte for byte
        /// (`AppSignature.entitlementsXML`). Where a store's profile and the app's signature disagree (a wildcard or
        /// shared App ID, entitlements trimmed at install), this is the one that agrees with the app.
        case appSigned

        init?(tag: String?) {
            switch tag {
            case EntitlementsChoice.profile.tag: self = .appProfile
            case EntitlementsChoice.app.tag: self = .appSigned
            default: return nil
            }
        }
    }

    /// `.appProfile`: probe test 5C loaded a framework from Documents and ran its remapped code page on an iPhone
    /// (iOS 27.0.1, free Apple ID, SideStore, 2026-11-10), where the same framework signed without them was refused.
    /// The copy grants nothing: a process's rights are the main executable's, so a game still gets exactly the app's.
    /// What makes the difference is that the loaded image agrees with the app about which app it belongs to.
    ///
    /// It is the default, and `SigningPreference` moves to `.appSigned` for an installation where dyld refuses a game
    /// signed so (`ShellHostModel.start`). A game's identity carries the choice (`SigningIdentity.entitlementsTag`)
    /// and its signing record remembers it, so a change re-signs the games by itself (`SigningRecord.needsResign`).
    public static let defaultEntitlements: Entitlements = .appProfile

    public let entitlements: Entitlements

    public init(entitlements: Entitlements = DeviceSigner.defaultEntitlements) {
        self.entitlements = entitlements
    }

    public func sign(framework: URL, identity: SigningIdentity) throws -> CodeSignatureInfo {
        guard let credentials = CertificateVault.credentials() else {
            throw NXPocketError(.noCertificate, "no certificate is installed")
        }
        let executable = try Self.executable(in: framework)
        #if canImport(NXZSign)
        // zsign reads both the certificate and the profile from paths, so the .p12 is written to a private temporary
        // file for the length of the call and removed on every way out. It is never stored anywhere permanent.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("nxpocket-\(UUID().uuidString).p12")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try credentials.p12.write(to: scratch, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratch.path)

        let provision = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision").path
        guard FileManager.default.fileExists(atPath: provision) else {
            // zsign takes the team ID and the entitlements from the profile: without it there is nothing to sign with.
            throw NXPocketError(.noCertificate, "this app has no embedded provisioning profile to sign with")
        }

        var error = [CChar](repeating: 0, count: 512)
        // zsign takes the entitlements from the provisioning profile we hand it unless a plist replaces them. For
        // `.none` an explicit empty dict keeps the app's capabilities out of the game; for `.appProfile` the path is
        // left empty so the profile's are written, the way probe test 5C does it.
        let entitlements = FileManager.default.temporaryDirectory
            .appendingPathComponent("nxpocket-\(UUID().uuidString)-entitlements.plist")
        defer { try? FileManager.default.removeItem(at: entitlements) }
        let entitlementsPath: String
        switch Entitlements(tag: identity.entitlementsTag) ?? self.entitlements {
        case .none:
            let empty = #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict/></plist>\#n"#
            try Data(empty.utf8).write(to: entitlements, options: [.atomic, .completeFileProtectionUnlessOpen])
            entitlementsPath = entitlements.path
        case .appProfile:
            entitlementsPath = ""
        case .appSigned:
            guard let signed = AppSignature.entitlementsXML else {
                throw NXPocketError(.signingFailed, "this app's own signature carries no entitlements to copy")
            }
            try signed.write(to: entitlements, options: [.atomic, .completeFileProtectionUnlessOpen])
            entitlementsPath = entitlements.path
        }

        // The framework folder and the name of the Mach-O inside it: zsign is handed the binary, not the bundle,
        // because it signs a .framework at the Mach-O level (ZBundle::SignFolder only accepts a .app). It writes
        // the framework's _CodeSignature/CodeResources itself, which codesign requires of a bundle.
        let status = nxpocket_zsign_sign(scratch.path, credentials.passphrase, provision,
                                         entitlementsPath, framework.path, executable.lastPathComponent,
                                         identity.identifier, &error, 512)
        guard status == 0 else {
            throw NXPocketError(.signingFailed, String(cString: error))
        }
        #else
        _ = executable
        throw NXPocketError(.signingFailed,
                            "this build has no signing engine: run tools/build_zsign.sh and rebuild, then sign again")
        #endif
        guard let image = try? MachOFile.parse(contentsOf: executable),
              let signature = try CodeSignatureInfo.read(image, path: executable.path) else {
            throw NXPocketError(.notSigned, "the framework came back with no signature")
        }
        guard signature.identifier == identity.identifier else {
            throw NXPocketError(.wrongSigner, "the framework was signed as \"\(signature.identifier)\"")
        }
        return signature
    }

    /// The single Mach-O inside the framework, as its `Info.plist` names it.
    public static func executable(in framework: URL) throws -> URL {
        let name = try executableName(in: framework)
        let url = framework.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NXPocketError(.packageMissing, "the framework has no executable named \(name)")
        }
        return url
    }

    public static func executableName(in framework: URL) throws -> String {
        let plist = framework.appendingPathComponent("Info.plist")
        guard let data = BoundedRead.dataIfPresent(at: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = parsed["CFBundleExecutable"] as? String, !name.isEmpty,
              SafePath.isSafeRelative(name) else {
            throw NXPocketError(.packageMissing, "\(framework.lastPathComponent) has no usable Info.plist")
        }
        return name
    }
}

/// What a signature leaves in `tmp/` if the app is killed before it cleans up: the certificate (`nxpocket-<uuid>.p12`)
/// and the entitlements file. Signing removes both on every way out, but a kill is not a way out; they are removed at
/// the next start, when nothing is signing.
public enum SigningLeftovers {
    public static func isLeftover(_ name: String) -> Bool {
        name.hasPrefix("nxpocket-") && (name.hasSuffix(".p12") || name.hasSuffix("-entitlements.plist"))
    }

    @discardableResult
    public static func clean(in folder: URL = FileManager.default.temporaryDirectory,
                             fileManager: FileManager = .default) -> [String] {
        var removed: [String] = []
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where isLeftover(name) {
            if (try? fileManager.removeItem(at: folder.appendingPathComponent(name))) != nil { removed.append(name) }
        }
        return removed.sorted()
    }
}

/// A signer that refuses, for the tests and for a build with no certificate.
public struct UnavailableSigner: FrameworkSigner {
    public init() {}
    public func sign(framework: URL, identity: SigningIdentity) throws -> CodeSignatureInfo {
        throw NXPocketError(.signingFailed, "no signing engine in this build")
    }
}
