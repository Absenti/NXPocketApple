import Foundation

/// Whether a newer NXPocket exists (`UpdateChannel`), checked on demand and, unless the player turned it off, by
/// itself at most once a day. It only reports: SideStore installs the update.
@MainActor
public final class UpdateChecker: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case done(UpdateChannel.Outcome)
    }

    enum Keys {
        static let automatic = "updates.automatic"
        static let lastCheck = "updates.lastCheck"
        static let dismissed = "updates.dismissedVersion"
    }

    static let interval: TimeInterval = 24 * 3600

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastCheck: Date?
    @Published public private(set) var dismissedVersion: String?
    @Published public var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Keys.automatic) }
    }

    public let version: String
    public let build: String?
    private let defaults: UserDefaults
    private let fetch: (URLRequest) async throws -> (Data, Int)

    public init(defaults: UserDefaults = .standard,
                version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                build: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                fetch: @escaping (URLRequest) async throws -> (Data, Int) = UpdateChannel.get) {
        self.defaults = defaults
        self.version = version
        self.build = build
        self.fetch = fetch
        automatic = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        dismissedVersion = defaults.string(forKey: Keys.dismissed)
    }

    public func check(now: Date = Date()) async {
        guard state != .checking else { return }
        state = .checking
        let outcome = await UpdateChannel.check(version: version, build: build, fetch: fetch)
        lastCheck = now
        defaults.set(now, forKey: Keys.lastCheck)
        state = .done(outcome)
    }

    /// The automatic check: when the player left it on, and a day after the last one.
    @discardableResult
    public func checkIfDue(now: Date = Date()) -> Task<Void, Never>? {
        guard automatic, state != .checking else { return nil }
        if let lastCheck, now.timeIntervalSince(lastCheck) < Self.interval, now >= lastCheck { return nil }
        return Task { await check(now: now) }
    }

    /// A newer release the player has not put off: the library mentions it.
    public var newerRelease: UpdateChannel.Release? {
        guard case .done(.newer(let release)) = state, release.version != dismissedVersion else { return nil }
        return release
    }

    public func dismiss(_ release: UpdateChannel.Release) {
        dismissedVersion = release.version
        defaults.set(release.version, forKey: Keys.dismissed)
    }

    /// "0.2.0 (7)".
    public var installed: String { build.map { "\(version) (\($0))" } ?? version }
}
