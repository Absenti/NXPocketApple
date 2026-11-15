import AppKit
import Combine
import Foundation
import NXPMacKit
import NXPocketKit

public enum SharingState: Equatable {
    case off
    case starting
    case listening(port: UInt16)
    case failed(String)
}

/// The titles the queue is building or packing right now, readable from the server's threads.
public final class BusyTitles: @unchecked Sendable {
    private let lock = NSLock()
    private var titles = Set<String>()
    public init() {}
    func set(_ new: Set<String>) { lock.withLock { titles = new } }
    public var current: Set<String> { lock.withLock { titles } }
}

/// What the server's inbox of saves reads from its own threads: where copies go and whether they are taken.
public final class InboxSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var _folder = URL(fileURLWithPath: NSHomeDirectory())
    private var _accepting = false
    public init() {}
    func set(folder: URL, accepting: Bool) { lock.withLock { _folder = folder; _accepting = accepting } }
    public var folder: URL { lock.withLock { _folder } }
    public var accepting: Bool { lock.withLock { _accepting } }
}

/// The launcher's side of `docs/SHARING.md`: the switch in Settings, the pairing code, the paired iPhones. Nothing
/// listens unless the player turned sharing on, and turning it off closes the port and cuts every connection.
extension AppModel {
    /// Called once, at launch: follows the Settings switch, the shared folder and the build folder from then on.
    func observeSharing() {
        observeInbox()
        observeBuilds()
        shareObserver = settings.$value
            .map { SharingKey(enabled: $0.shareEnabled, folder: $0.shareURL.path) }
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.applySharing() } }
    }

    /// Keeps the board of builds current: the dump folder, the queue and the switch.
    func observeBuilds() {
        buildBoard.ask = { [weak self] titleID in Task { @MainActor in self?.queueBuild(titleID: titleID) } }
        buildObserver = Publishers.CombineLatest3($folder, $queue, settings.$value).sink { [buildBoard] folder, queue, settings in
            let games = folder.games.filter(\.hasBase).map { game -> RemoteBuildable in
                var entry = RemoteBuildable(titleID: game.titleID, name: game.name, state: .idle)
                guard let item = queue.last(where: { $0.titleID == game.titleID && $0.builds }) else { return entry }
                switch item.phase {
                case .waiting: entry.state = .queued
                case .building, .packing, .sending, .needsAnswer, .done:
                    entry.state = .building
                    entry.progress = item.fraction
                case .failed(let reason):
                    entry.state = .failed
                    entry.detail = String(reason.prefix(160))
                case .cancelled: break
                }
                return entry
            }
            buildBoard.set(games, allowed: settings.shareAllowBuilds)
        }
    }

    /// Keeps the inbox's view of the settings current without restarting the server.
    func observeInbox() {
        inboxObserver = settings.$value.sink { [inboxSettings] value in
            inboxSettings.set(folder: value.outputURL, accepting: value.shareAcceptSaves)
        }
    }

    private struct SharingKey: Equatable { var enabled: Bool; var folder: String }

    /// The address a phone can type: this Mac's name on the local network and the port.
    public var sharingAddress: String? {
        guard case .listening(let port) = sharing else { return nil }
        return "\(ProcessInfo.processInfo.hostName):\(port)"
    }

    /// What the QR code says: this Mac's address and key, and the secret of the open pairing window.
    public var pairingLink: URL? {
        guard case .listening(let port) = sharing, let server = shareServer, let offer = pairingOffer else { return nil }
        let host = ProcessInfo.processInfo.hostName
        return PairLink(address: host, port: Int(port), pin: server.pin, secret: offer.secret,
                        name: Host.current().localizedName ?? host).url
    }

    func applySharing() {
        shareTask?.cancel()
        let enabled = settings.value.shareEnabled
        shareTask = Task { @MainActor in
            await self.stopSharingServer()
            guard enabled, !Task.isCancelled else { return }
            await self.startSharingServer()
        }
    }

    private func stopSharingServer() async {
        pairingExpiry?.cancel()
        shareServer?.stop()
        shareServer = nil
        sharing = .off
        pairingOffer = nil
        pairRequest = nil
        sharingConnections = 0
        sharingTransfers = []
    }

    private func startSharingServer() async {
        sharing = .starting
        let folder = settings.value.shareURL
        let port = UInt16(clamping: max(settings.value.sharePort, 0))
        let busy = busyTitles
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let keyFolder = sharingKeyFolder
        let advertise = advertiseSharing
        let inbox = inboxSettings
        let board = buildBoard
        do {
            // The server is made off the main thread (it reads the key file and the list of paired iPhones), and started where it
            // is used. Making and starting are two steps, not one returned tuple: a tuple built around a call that can throw and
            // be retried crashed the release build at the second launch, with sharing on and a port already kept.
            let server = try await Task.detached(priority: .userInitiated) { () -> ShareServer in
                let identity = try ServerIdentity.load(from: keyFolder)
                let library = SharedLibrary(folder: folder, busy: { busy.current })
                let devices = PairedDevices(folder: keyFolder)
                let log: @Sendable (String) -> Void = { [weak self] line in
                    Task { @MainActor in self?.append("sharing: \(line)") }
                }
                let changed: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.refreshSharing() } }
                let saves = SaveInbox(outputFolder: { inbox.folder }, accepting: { inbox.accepting })
                return ShareServer(identity: identity, library: library, devices: devices, name: name, saves: saves, builds: board,
                                   log: log, onChange: changed)
            }.value
            var bound: UInt16
            do {
                bound = try await server.start(port: port, advertise: advertise)
            } catch where port != 0 {
                // The port kept from last time is taken by something else: a new one is chosen, and kept.
                bound = try await server.start(port: 0, advertise: advertise)
            }
            if Task.isCancelled { server.stop(); return }
            shareServer = server
            if settings.value.sharePort != Int(bound) { settings.value.sharePort = Int(bound) }
            sharingFingerprint = TLSPin.display(server.pin)
            sharing = .listening(port: bound)
            refreshSharing()
        } catch {
            sharing = .failed((error as? NXPocketError)?.detail ?? error.localizedDescription)
            append("sharing: could not start: \(sharing)")
        }
    }

    /// Reads what the server knows into what the window shows.
    func refreshSharing() {
        guard let server = shareServer else { return }
        pairedDevices = server.devices.all
        pairingOffer = server.pairing.current
        pairRequest = server.pairing.request
        sharingConnections = server.activeConnections
        sharingTransfers = server.activeTransfers
        // While something is downloading the list is read again every second, so a download that stops leaves it by itself.
        if !sharingTransfers.isEmpty, transferTick == nil {
            transferTick = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.transferTick = nil
                self?.refreshSharing()
            }
        }
    }

    // MARK: Pairing

    public func beginPairing() {
        guard let server = shareServer, let offer = server.beginPairing() else { return }
        pairingOffer = offer
        pairingExpiry?.cancel()
        pairingExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(offer.expires.timeIntervalSinceNow, 0) * 1_000_000_000) + 500_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshSharing()
        }
    }

    /// The number on the iPhone is the one on this screen.
    public func allowPairRequest() { shareServer?.pairing.approve(); refreshSharing() }
    public func refusePairRequest() { shareServer?.pairing.deny(); refreshSharing() }

    public func cancelPairing() {
        shareServer?.cancelPairing()
        pairingOffer = nil
        pairRequest = nil
        pairingExpiry?.cancel()
    }

    public func revokeDevice(_ device: PairedDevice) {
        shareServer?.revoke(deviceID: device.id)
        refreshSharing()
    }

    /// A new key: every paired iPhone has to pair again. The old key and the list of phones are gone for good.
    public func resetSharing() {
        let wasOn = settings.value.shareEnabled
        let keyFolder = sharingKeyFolder
        shareTask?.cancel()
        shareTask = Task { @MainActor in
            await self.stopSharingServer()
            _ = try? await Task.detached { () -> ServerIdentity in
                let fresh = try ServerIdentity.reset(in: keyFolder)
                PairedDevices(folder: keyFolder).removeAll()
                return fresh
            }.value
            self.pairedDevices = []
            self.append("sharing: the key was replaced; every iPhone has to pair again")
            if wasOn { await self.startSharingServer() }
        }
    }

    public func chooseShareFolder() {
        if let url = Panel.chooseDirectory(title: "Choose the folder iPhones may download built games from") {
            settings.value.shareFolder = url.path
        }
    }
}
