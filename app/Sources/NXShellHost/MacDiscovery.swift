import Foundation
import Network

/// A Mac that advertised itself as sharing its games, with the address it can be reached at.
public struct DiscoveredMac: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    /// The first characters of the key it presents, from its advertisement: enough to tell a Mac already paired.
    public var fingerprint: String?
}

/// Looks for Macs on this network (Bonjour, `_nxpocket._tcp`). It runs only while the player is on the screen that adds a
/// Mac, which is also when iOS asks for the local network permission: nothing browses in the background.
///
/// What an advertisement says is not trusted for anything but a name and an address: a forged one leads to a Mac whose key
/// is not the one the code is for, and the pairing refuses it.
@MainActor
public final class MacDiscovery: ObservableObject {
    @Published public private(set) var found: [DiscoveredMac] = []
    @Published public private(set) var searching = false
    /// iOS refused the local network permission.
    @Published public private(set) var denied = false

    private var browser: NWBrowser?
    private var resolving: [String: Task<Void, Never>] = [:]

    public init() {}

    public func start() {
        stop()
        found = []
        denied = false
        searching = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_nxpocket._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.searching = false
                case .waiting(let error):
                    if case .dns(let code) = error, code == -65570 { self?.denied = true }
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        searching = false
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var ids = Set<String>()
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            let id = name
            ids.insert(id)
            if found.contains(where: { $0.id == id }) || resolving[id] != nil { continue }
            var fingerprint: String?
            if case .bonjour(let record) = result.metadata { fingerprint = record["fp"] }
            resolving[id] = Task { [weak self] in
                let address = await Self.resolve(result.endpoint)
                await MainActor.run {
                    guard let self else { return }
                    self.resolving[id] = nil
                    guard let address else { return }
                    self.found.append(DiscoveredMac(id: id, name: name, host: address.host, port: address.port, fingerprint: fingerprint))
                }
            }
        }
        found.removeAll { !ids.contains($0.id) }
    }

    /// The IPv4 address and port behind a Bonjour name: a connection is opened to it and the address it reached is read.
    /// IPv4 only: a link-local IPv6 address needs an interface name that a URL cannot carry well.
    private static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 6) async -> (host: String, port: Int)? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        return await withCheckedContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var result: (String, Int)?
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint, case .ipv4(let address) = host {
                        // The address prints with the interface it was found on ("192.168.1.12%en0"): a URL cannot carry that.
                        result = ("\(address)".split(separator: "%").first.map(String.init) ?? "\(address)", Int(port.rawValue))
                    }
                    connection.cancel()
                    if once.fire() { continuation.resume(returning: result) }
                case .failed, .cancelled:
                    if once.fire() { continuation.resume(returning: nil) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                if once.fire() { continuation.resume(returning: nil) }
            }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}
