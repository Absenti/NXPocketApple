import Foundation
import NXPocketKit

/// The game's data is large and reproducible from the user's own dumps: it is kept out of iCloud backups.
public enum BackupExclusion {
    public static func exclude(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public static func excludeImportantFolders(in documents: URL) {
        for name in [GameLayout.gamesFolder, GameLayout.incomingFolder] {
            exclude(documents.appendingPathComponent(name, isDirectory: true))
        }
    }
}

@_silgen_name("os_proc_available_memory")
private func os_proc_available_memory() -> Int

/// What a game may allocate. A framework inherits the app's entitlements, so this is the app's own budget.
public enum MemoryBudget {
    public static var availableBytes: Int64 { Int64(os_proc_available_memory()) }
    public static var physicalBytes: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    public static var availableText: String {
        ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .memory)
    }

    public static var physicalText: String {
        ByteCountFormatter.string(fromByteCount: physicalBytes, countStyle: .memory)
    }

    /// Whether the profile that installed this app carries the increased-memory entitlement. Read from the
    /// embedded profile rather than from a private API.
    public static var hasIncreasedLimit: Bool {
        ProvisioningProfile.entitlements()["com.apple.developer.kernel.increased-memory-limit"] != nil
    }
}

/// The profile an installer put in the bundle: the team, the expiry and the entitlements the app was granted.
public enum ProvisioningProfile {
    /// The installed app's profile does not change while it runs; the settings screen asked for it on every redraw.
    private static let mainDictionary: [String: Any]? = read(bundle: .main)

    public static func dictionary(bundle: Bundle = .main) -> [String: Any]? {
        bundle == .main ? mainDictionary : read(bundle: bundle)
    }

    private static func read(bundle: Bundle) -> [String: Any]? {
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url) else { return nil }
        // The profile is a CMS blob with an XML plist inside it.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
    }

    public static func entitlements(bundle: Bundle = .main) -> [String: Any] {
        (dictionary(bundle: bundle)?["Entitlements"] as? [String: Any]) ?? [:]
    }

    /// The team that installed this app: the certificate that signs a game must belong to it.
    public static func teamID(bundle: Bundle = .main) -> String? {
        (dictionary(bundle: bundle)?["TeamIdentifier"] as? [String])?.first
    }

    public static func appIdentifier(bundle: Bundle = .main) -> String? {
        entitlements(bundle: bundle)["application-identifier"] as? String
    }

    /// The SHA-256 of each certificate the profile allows (`DeveloperCertificates`, DER), the way
    /// `StoredCertificate.sha256` is computed. Nil when the app carries no profile (the simulator).
    public static func certificateHashes(bundle: Bundle = .main) -> Set<String>? {
        certificateHashes(in: dictionary(bundle: bundle))
    }

    static func certificateHashes(in profile: [String: Any]?) -> Set<String>? {
        guard let certificates = profile?["DeveloperCertificates"] as? [Data] else { return nil }
        return Set(certificates.map { FileDigest.sha256(of: $0) })
    }

    /// Whether `certificate` is one this app's current profile allows. SideStore renews the profile every 7 days:
    /// after a renewal that made a new certificate, the one imported here is no longer in it, the games it signs can
    /// stop loading, and the .p12 has to be exported and imported again. Nil when there is no profile to ask.
    public static func allows(certificateSHA256 sha256: String, bundle: Bundle = .main) -> Bool? {
        certificateHashes(bundle: bundle).map { $0.contains(sha256.lowercased()) || $0.contains(sha256.uppercased()) }
    }
}

/// When this process started, from the kernel: what a launch time is measured from.
public enum ProcessStart {
    public static let date: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()
}

/// `Documents/.launching`: written and flushed before a `dlopen`, cleared once the game is up. A marker still there
/// at the next start means the last launch killed the app.
public enum LaunchGuard {
    public static func willLaunch(titleID: TitleID, in documents: URL) throws {
        try LaunchMarker.write(LaunchMarker(titleID: titleID), in: documents)
    }

    public static func didLaunch(in documents: URL) {
        LaunchMarker.clear(in: documents)
    }

    /// The launch that did not come back. A marker that is there but cannot be read (cut short as the app died) is
    /// still one: it reads as title ID zero, a game the notice cannot name, rather than as no failure at all.
    public static func failedLaunch(in documents: URL) -> LaunchMarker? {
        if let marker = LaunchMarker.read(in: documents) { return marker }
        let url = LaunchMarker.url(in: documents)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return LaunchMarker(titleID: TitleID(rawValue: 0), startedAt: attributes[.modificationDate] as? Date ?? Date())
    }

    public static func clear(in documents: URL) {
        LaunchMarker.clear(in: documents)
    }
}

/// Free space that a new import may use. iOS reports two numbers; the one for "important usage" is what a user
/// adding a game cares about.
public enum VolumeSpace {
    public static func available(documents: URL) -> Int64? {
        guard let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }

    public static func total(documents: URL) -> Int64? {
        guard let values = try? documents.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let capacity = values.volumeTotalCapacity else { return nil }
        return Int64(capacity)
    }

    public static func text(_ bytes: Int64?) -> String {
        guard let bytes else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
