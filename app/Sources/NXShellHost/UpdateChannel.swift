import Foundation

/// The app's one call to a server it does not belong to: one GET of the SideStore source the project publishes with each
/// release, to say whether a newer NXPocketApple exists. Nothing about the player or the phone is sent: no cookie, no
/// cache, no query, no identifier beyond what any HTTP client sends. Installing an update is SideStore's job, never this
/// app's. (The network sources of `NetworkSources` talk to the player's own Mac or SFTP server, and only once the player
/// turned them on; they are a separate switch from this check's.)
public enum UpdateChannel {
    /// The source CI publishes with each release (AltStore/SideStore source format). It stays at this address.
    public static let sourceURL = URL(string: "https://github.com/Absenti/NXPocketApple/releases/latest/download/source.json")!
    public static let bundleID = "dev.nxpocketapple.app"
    public static let timeout: TimeInterval = 10
    static let maxBytes = 1 << 20

    /// `sidestore://source?url=…`: SideStore adds the source and lists NXPocketApple's releases from it.
    public static var addSourceURL: URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = sourceURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "sidestore://source?url=\(encoded)")!
    }

    public static let openSideStoreURL = URL(string: "sidestore://")!

    /// A release as the source describes it.
    public struct Release: Equatable, Sendable {
        public var version: String
        public var build: String?
        public var date: Date?
        public var size: Int64?
        public var downloadURL: URL?
    }

    public enum Outcome: Equatable, Sendable {
        case newer(Release)
        case upToDate(Release)
        /// The source is not reachable without an account (the repository is private) or not published yet.
        case noPublicChannel
        case failed(String)
    }

    /// NXPocketApple's newest release in a source: the app with this bundle ID, its `versions` (the newest of them, by
    /// version then build) or, in an older source, the app's own `version` fields.
    public static func newestRelease(in data: Data, bundleID: String = bundleID) -> Release? {
        guard let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = source["apps"] as? [[String: Any]],
              let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == bundleID }) else { return nil }
        let entries = (app["versions"] as? [[String: Any]] ?? []).compactMap(release)
        if let newest = entries.max(by: { isOlder($0, than: $1) }) { return newest }
        return release(app)
    }

    static func release(_ entry: [String: Any]) -> Release? {
        guard let version = entry["version"] as? String, isVersion(version) else { return nil }
        let date = (entry["date"] as? String ?? entry["versionDate"] as? String).flatMap(parseDate)
        let size = (entry["size"] as? NSNumber)?.int64Value
        let download = (entry["downloadURL"] as? String).flatMap(URL.init(string:))
        let build = (entry["buildVersion"] as? String) ?? (entry["buildVersion"] as? NSNumber)?.stringValue
        return Release(version: version, build: build, date: date, size: size, downloadURL: download)
    }

    static func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: text)
    }

    static func isVersion(_ text: String) -> Bool {
        !text.isEmpty && text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// Numeric, part by part: 0.10.0 is newer than 0.9.1, and 1.0 equals 1.0.0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// A release is newer than the installed app by version, then, for the same version, by build when both have one.
    public static func isNewer(_ release: Release, thanVersion version: String, build: String?) -> Bool {
        switch compare(release.version, version) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame:
            guard let theirs = release.build, let ours = build else { return false }
            return compare(theirs, ours) == .orderedDescending
        }
    }

    static func isOlder(_ a: Release, than b: Release) -> Bool {
        switch compare(a.version, b.version) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return compare(a.build ?? "0", b.build ?? "0") == .orderedAscending
        }
    }

    /// What one request answers. `fetch` is the network, replaced in the tests.
    public static func check(version: String, build: String?,
                             fetch: (URLRequest) async throws -> (Data, Int) = Self.get) async -> Outcome {
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, status) = try await fetch(request)
            // A private repository's release asset answers 404 to anyone without an account.
            if [401, 403, 404].contains(status) { return .noPublicChannel }
            guard (200..<300).contains(status) else { return .failed("HTTP \(status)") }
            guard data.count <= maxBytes, let release = newestRelease(in: data) else { return .noPublicChannel }
            return isNewer(release, thanVersion: version, build: build) ? .newer(release) : .upToDate(release)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The GET itself, on a session that keeps nothing: no cookie, no cache, no credential.
    public static func get(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
