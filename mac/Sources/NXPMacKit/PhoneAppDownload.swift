import Foundation
import NXPocketKit

/// The iPhone app's IPA, taken from the project's GitHub release instead of being built: downloaded with the release's
/// SHA256SUMS, checked against it, checked to be the app (its bundle identifier), and only then put in place.
public enum PhoneAppDownload {
    public static let assetName = "NXPocketApple-iPhone.ipa"
    /// The identifier SideStore installs it under: another one is not this app.
    public static let bundleID = "dev.nxpocketapple.app"
    /// The largest IPA taken from a release (the app is under 10 MB today): a bigger one is no update, it is stopped.
    public static let maxBytes: Int64 = 300 << 20

    /// Whether the release carries the IPA and the sums to check it against.
    public static func hasIPA(_ release: LauncherRelease) -> Bool {
        release.assets[assetName] != nil && release.assets[LauncherUpdate.sumsName] != nil
    }

    /// Whether the copy kept here is older than the release's: none at all, or a lower version.
    public static func needsDownload(have: PhoneAppIPA?, release: LauncherRelease) -> Bool {
        guard hasIPA(release) else { return false }
        guard let have, let version = have.version.flatMap(SemanticVersion.init) else { return true }
        return version < release.version
    }

    /// The IPA that came inside the launcher (tools/build_mac.sh puts it in the app's resources), nil when there is none.
    public static func bundledIPA(_ bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "NXPocketApple", withExtension: "ipa")
    }

    /// Puts the launcher's own copy of the IPA at `destination` when none is there or the one there is older, so the
    /// iPhone app is available before any release has been downloaded. A newer copy (downloaded or built here, by version, then by date) is kept.
    /// Returns the copy now in place when it changed, nil otherwise.
    @discardableResult
    public static func seed(from bundled: URL, to destination: URL) -> PhoneAppIPA? {
        guard let source = PhoneAppBuild.inspect(bundled), source.bundleID == bundleID else { return nil }
        let fileManager = FileManager.default
        // Two builds of the same version are told apart by their date (the bundled copy keeps the date it was built): the newer one stays.
        if let have = PhoneAppBuild.inspect(destination), have.bundleID == bundleID,
           let haveVersion = have.version.flatMap(SemanticVersion.init), let sourceVersion = source.version.flatMap(SemanticVersion.init),
           haveVersion > sourceVersion || (haveVersion == sourceVersion && have.date >= source.date) { return nil }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".NXPocketApple-\(UUID().uuidString).ipa")
            try fileManager.copyItem(at: bundled, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            return PhoneAppBuild.inspect(destination)
        } catch {
            return nil
        }
    }

    /// Downloads, checks and puts the release's IPA at `destination`. The previous file is replaced only once the new one
    /// is whole and right.
    public static func fetch(_ release: LauncherRelease, to destination: URL,
                             progress: @escaping SetupDownload.Progress) throws -> PhoneAppIPA {
        guard let ipa = release.assets[assetName], let sums = release.assets[LauncherUpdate.sumsName] else {
            throw NXPocketError(.packageMissing, "release \(release.tag) has no \(assetName) or no \(LauncherUpdate.sumsName)")
        }
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("nxpocket-ipa-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let sumsFile = staging.appendingPathComponent(LauncherUpdate.sumsName)
        try SetupDownload.fetch(sums, to: sumsFile, userAgent: LauncherUpdate.userAgent) { _, _ in }
        let text = String(data: try BoundedRead.data(at: sumsFile, limit: 64 << 10), encoding: .utf8) ?? ""
        guard let expected = LauncherUpdate.checksums(in: text)[assetName] else {
            throw NXPocketError(.packageDamaged, "\(LauncherUpdate.sumsName) of \(release.tag) has no line for \(assetName)")
        }
        let file = staging.appendingPathComponent(assetName)
        try SetupDownload.fetch(ipa, to: file, userAgent: LauncherUpdate.userAgent, maxBytes: maxBytes, progress: progress)
        let digest = try FileDigest.sha256(ofFileAt: file)
        guard digest == expected else {
            throw NXPocketError(.packageDamaged, "\(assetName) does not match \(LauncherUpdate.sumsName) (\(digest.prefix(12))…): refused")
        }
        guard let found = PhoneAppBuild.inspect(file), found.bundleID == bundleID else {
            throw NXPocketError(.packageDamaged, "the downloaded IPA is not NXPocketApple (its identifier is \(PhoneAppBuild.inspect(file)?.bundleID ?? "unreadable"))")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: file)
        } else {
            try fileManager.moveItem(at: file, to: destination)
        }
        return PhoneAppBuild.inspect(destination) ?? found
    }
}
