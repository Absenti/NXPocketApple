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
        /// The app's own entitlements, out of its provisioning profile: what LiveContainer's re-signing amounts to,
        /// and exactly what probe test 5C signs with (an empty entitlements path, so zsign takes the profile's).
        case appProfile
    }

    /// `.appProfile`: probe test 5C loaded a framework from Documents and ran its remapped code page on an iPhone
    /// (iOS 27.0.1, free Apple ID, SideStore, 2026-11-10), where the same framework signed without them was refused.
    /// The copy grants nothing: a process's rights are the main executable's, so a game still gets exactly the app's.
    /// What makes the difference is that the loaded image agrees with the app about which app it belongs to.
    ///
    /// Games signed under another choice are not re-signed by themselves (`needsResign` looks at the certificate
    /// only): remove and import them again after a change.
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

        guard let provision = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision").path as String?,
              FileManager.default.fileExists(atPath: provision) else {
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
        switch self.entitlements {
        case .none:
            let empty = #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict/></plist>\#n"#
            try Data(empty.utf8).write(to: entitlements, options: [.atomic, .completeFileProtectionUnlessOpen])
            entitlementsPath = entitlements.path
        case .appProfile:
            entitlementsPath = ""
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

/// A signer that refuses, for the tests and for a build with no certificate.
public struct UnavailableSigner: FrameworkSigner {
    public init() {}
    public func sign(framework: URL, identity: SigningIdentity) throws -> CodeSignatureInfo {
        throw NXPocketError(.signingFailed, "no signing engine in this build")
    }
}
