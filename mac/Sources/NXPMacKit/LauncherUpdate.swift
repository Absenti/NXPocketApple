import Foundation
import NXPocketKit

/// A version as the releases write it: `0.2.0`, `v0.2.0`, `0.3.0-beta.1`. Compared as semantic versioning says: by
/// number, and a pre-release before its release.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix("v") || rest.hasPrefix("V") { rest.removeFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = String(rest[..<plus]) }   // build metadata does not count
        let parts = rest.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            prerelease = identifiers
        } else {
            prerelease = []
        }
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // 1.0.0-beta < 1.0.0; between pre-releases, identifier by identifier, numbers below words.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// A release of the project on GitHub, as `releases/latest` gives it.
public struct LauncherRelease: Equatable, Sendable {
    public var tag: String
    public var version: SemanticVersion
    public var title: String
    public var notes: String
    public var page: URL
    public var isDraft: Bool
    public var isPrerelease: Bool
    /// Asset name → download URL.
    public var assets: [String: URL]
}

public enum UpdateCheckOutcome: Equatable, Sendable {
    case upToDate(SemanticVersion)
    case available(LauncherRelease)
    /// 404: the repository is private, or has no release yet. Said once, never retried in a loop.
    case noPublicChannel
    case failed(String)
}

/// The launcher's own updates, from the project's GitHub releases. Nothing personal is sent: one unauthenticated GET
/// with the User-Agent GitHub requires, then the release's own files.
public enum LauncherUpdate {
    public static let repository = "Absenti/NXPocketApple"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    public static let userAgent = "NXPocketApple-Launcher"
    public static let bundleID = "dev.nxpocket.launcher"
    public static let zipName = "NXPocketApple-macOS.zip"
    public static let sumsName = "SHA256SUMS"

    /// The running launcher's version, nil for a build that is not a bundle (the plain `swift build` executable).
    public static func runningVersion(_ bundle: Bundle = .main) -> SemanticVersion? {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemanticVersion.init)
    }

    // MARK: - Checking

    public static func latest(current: SemanticVersion?) async -> UpdateCheckOutcome {
        await latestWithRelease(current: current).outcome
    }

    /// The same look, also giving the latest published release itself (when there is one): the launcher's update and
    /// the iPhone app's IPA both come from it, so it is asked for once.
    public static func latestWithRelease(current: SemanticVersion?) async -> (outcome: UpdateCheckOutcome, release: LauncherRelease?) {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = status == 200 ? (try? parse(data)).flatMap { stable($0) ? $0 : nil } : nil
            return (outcome(status: status, data: data, current: current), release)
        } catch {
            return (.failed("GitHub could not be reached: \(error.localizedDescription)"), nil)
        }
    }

    /// A release people are meant to install: not a draft, not a pre-release.
    static func stable(_ release: LauncherRelease) -> Bool {
        !release.isDraft && !release.isPrerelease && !release.version.isPrerelease
    }

    /// What an answer of `releases/latest` means for the running version.
    public static func outcome(status: Int, data: Data, current: SemanticVersion?) -> UpdateCheckOutcome {
        switch status {
        case 200: break
        case 404: return .noPublicChannel
        case 403, 429: return .failed("GitHub refused for now (its limit for unauthenticated checks): try again later")
        default: return .failed("GitHub answered \(status)")
        }
        let release: LauncherRelease
        do {
            release = try parse(data)
        } catch {
            return .failed((error as? NXPocketError)?.detail ?? "\(error)")
        }
        guard !release.isDraft, !release.isPrerelease, !release.version.isPrerelease else { return .noPublicChannel }
        guard let current else { return .available(release) }
        return release.version > current ? .available(release) : .upToDate(release.version)
    }

    public static func parse(_ data: Data) throws -> LauncherRelease {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NXPocketError(.packageDamaged, "the release information is not JSON")
        }
        guard let tag = object["tag_name"] as? String, let version = SemanticVersion(tag) else {
            throw NXPocketError(.packageDamaged, "the release's tag is not a version (\(object["tag_name"] ?? "none"))")
        }
        var assets: [String: URL] = [:]
        for asset in object["assets"] as? [[String: Any]] ?? [] {
            guard let name = asset["name"] as? String, let link = asset["browser_download_url"] as? String,
                  let url = URL(string: link), url.scheme == "https" else { continue }
            assets[name] = url
        }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return LauncherRelease(tag: tag, version: version, title: object["name"] as? String ?? tag,
                               notes: object["body"] as? String ?? "", page: page,
                               isDraft: object["draft"] as? Bool ?? false, isPrerelease: object["prerelease"] as? Bool ?? false,
                               assets: assets)
    }

    /// `shasum -a 256` lines: `<64 hex>  <name>`, or `<64 hex> *<name>` in binary mode. Other lines are skipped.
    public static func checksums(in text: String) -> [String: String] {
        var sums: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 66, let space = line.firstIndex(of: " ") else { continue }
            let hash = line[..<space].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            var name = line[space...].drop { $0 == " " }
            if name.first == "*" { name = name.dropFirst() }
            if !name.isEmpty { sums[String(name)] = hash }
        }
        return sums
    }

    // MARK: - Installing

    /// Why the running launcher cannot replace itself, nil when it can. A development build checks for updates but is
    /// only offered the release page.
    public static func refusal(for bundle: URL, fileManager: FileManager = .default) -> String? {
        let path = bundle.standardizedFileURL.path
        guard bundle.pathExtension == "app" else {
            return "This launcher runs as a plain executable (a development build): download the new one from the release page."
        }
        if path.contains("/.build/") {
            return "This launcher is a development build (\(path)): download the release from its page."
        }
        if path.contains("/AppTranslocation/") {
            return "macOS runs this launcher from a read-only copy. Move NXPocketApple.app to Applications, open it from there, then update."
        }
        let parent = bundle.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent), fileManager.isWritableFile(atPath: bundle.path) else {
            return "\(parent) cannot be written by you: download the new launcher from the release page."
        }
        return nil
    }

    /// Downloads the release's zip and SHA256SUMS next to `app` (same volume, so the swap is a rename), checks the zip
    /// against its line, unpacks it and checks the app inside. Returns the new app, ready to be put in place.
    public static func prepare(_ release: LauncherRelease, current: SemanticVersion?, replacing app: URL,
                               progress: @escaping SetupDownload.Progress) throws -> URL {
        guard let zip = release.assets[zipName], let sums = release.assets[sumsName] else {
            throw NXPocketError(.packageMissing, "release \(release.tag) has no \(zipName) or no \(sumsName)")
        }
        let fileManager = FileManager.default
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        do {
            let sumsFile = staging.appendingPathComponent(sumsName)
            try SetupDownload.fetch(sums, to: sumsFile, userAgent: userAgent) { _, _ in }
            let text = String(data: try BoundedRead.data(at: sumsFile, limit: 64 << 10), encoding: .utf8) ?? ""
            guard let expected = checksums(in: text)[zipName] else {
                throw NXPocketError(.packageDamaged, "\(sumsName) of \(release.tag) has no line for \(zipName)")
            }
            let archive = staging.appendingPathComponent(zipName)
            try SetupDownload.fetch(zip, to: archive, userAgent: userAgent, progress: progress)
            let digest = try FileDigest.sha256(ofFileAt: archive)
            guard digest == expected else {
                throw NXPocketError(.packageDamaged, "\(zipName) does not match \(sumsName) (\(digest.prefix(12))…): refused")
            }
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            let ditto = try ProcessRunner.capture(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, unpacked.path],
                                                  timeout: 300)
            guard ditto.status == 0 else { throw NXPocketError(.packageDamaged, "\(zipName) could not be unpacked") }
            let apps = ((try? fileManager.contentsOfDirectory(atPath: unpacked.path)) ?? []).filter { $0.hasSuffix(".app") }
            guard apps.count == 1 else {
                throw NXPocketError(.packageDamaged, "\(zipName) holds \(apps.count) apps, not one")
            }
            let newApp = unpacked.appendingPathComponent(apps[0], isDirectory: true)
            try check(newApp, release: release.version, current: current)
            return newApp
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// The unpacked app is the launcher, at the release's version, newer than the running one, and its signature holds.
    public static func check(_ app: URL, release: SemanticVersion, current: SemanticVersion?) throws {
        guard let data = try? BoundedRead.data(at: app.appendingPathComponent("Contents/Info.plist"), limit: 1 << 20),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw NXPocketError(.packageDamaged, "the downloaded app has no Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw NXPocketError(.packageDamaged, "the downloaded app is \(info["CFBundleIdentifier"] ?? "unnamed"), not \(bundleID)")
        }
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init), version == release else {
            throw NXPocketError(.packageDamaged, "the downloaded app says version \(info["CFBundleShortVersionString"] ?? "none"), the release \(release)")
        }
        if let current, version <= current {
            throw NXPocketError(.packageDamaged, "the downloaded app (\(version)) is not newer than this one (\(current))")
        }
        let signature = try ProcessRunner.capture(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", app.path])
        guard signature.status == 0 else {
            throw NXPocketError(.packageDamaged, "the downloaded app's signature does not verify")
        }
    }

    /// The script that waits for the running launcher (`pid`) to exit, moves it to `trashed` (in the Trash, never
    /// deleted), moves `newApp` to its place and opens it. If the move in fails, the old app is put back and opened.
    public static func swapScript(app: URL, newApp: URL, trashed: URL, staging: URL, pid: Int32,
                                  opener: String = "/usr/bin/open") -> String {
        """
        #!/bin/sh
        # Written by the NXPocketApple launcher to replace itself once it has quit.
        OLD=\(quote(app.path))
        NEW=\(quote(newApp.path))
        TRASHED=\(quote(trashed.path))
        STAGING=\(quote(staging.path))
        PID=\(pid)
        i=0
        while kill -0 "$PID" 2>/dev/null; do
            i=$((i + 1))
            [ "$i" -gt 600 ] && exit 1
            sleep 0.1
        done
        [ -e "$TRASHED" ] && exit 1
        mv "$OLD" "$TRASHED" || exit 1
        if ! mv "$NEW" "$OLD"; then
            mv "$TRASHED" "$OLD"
            \(opener) "$OLD"
            exit 1
        fi
        rm -rf "$STAGING"
        \(opener) "$OLD"

        """
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Where the running app goes: the Trash of its volume, under a name that is not taken.
    public static func trashDestination(for app: URL, version: SemanticVersion?, fileManager: FileManager = .default) throws -> URL {
        let trash = try fileManager.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        let stamp = Int(Date().timeIntervalSince1970)
        return trash.appendingPathComponent("NXPocketApple \(version?.description ?? "old") \(stamp).app", isDirectory: true)
    }

    /// Writes the swap script and starts it; the caller quits right after. The script outlives this process.
    public static func startSwap(app: URL, newApp: URL, version: SemanticVersion?) throws {
        // The script removes `staging` once done: it must be the folder `prepare` made, nothing above it.
        guard newApp.deletingLastPathComponent().lastPathComponent == "unpacked" else {
            throw NXPocketError(.packageDamaged, "the new app is not where the update unpacked it")
        }
        let staging = newApp.deletingLastPathComponent().deletingLastPathComponent()
        let trashed = try trashDestination(for: app, version: version)
        let script = staging.appendingPathComponent("swap.sh")
        try Data(swapScript(app: app, newApp: newApp, trashed: trashed, staging: staging,
                            pid: ProcessInfo.processInfo.processIdentifier).utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
