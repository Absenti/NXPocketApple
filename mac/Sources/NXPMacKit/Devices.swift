import Foundation
import NXPocketKit

public struct Device: Identifiable, Sendable, Equatable, Hashable {
    public var udid: String
    public var name: String
    public var model: String
    public var productType: String
    public var osVersion: String?
    public var isPhysical: Bool
    public var isPaired: Bool
    public var isConnected: Bool
    public var transport: String?

    public var id: String { udid }
    public var isSimulator: Bool { !isPhysical }
    public var summary: String { "\(model) · iOS \(osVersion ?? "?")" }
    public var canReceive: Bool { isPhysical && isPaired }
}

/// `xcrun devicectl list devices --json-output`, read from `result.devices[].properties`.
public enum DeviceInventory {
    public static func list(toolchain: Toolchain) throws -> [Device] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("nxpocket-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try ProcessRunner.capture(toolchain.xcrun,
                                               ["devicectl", "list", "devices", "--json-output", output.path],
                                               timeout: 60)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw NXPocketError(.deviceUnavailable, result.lines.suffix(3).joined(separator: " "))
        }
        return try parse(json: BoundedRead.data(at: output, limit: DeviceTransfer.listingLimit))
    }

    public static func parse(json: Data) throws -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let raw = result["devices"] as? [[String: Any]] else {
            throw NXPocketError(.deviceUnavailable, "devicectl returned something this app does not understand")
        }
        return raw.compactMap { entry -> Device? in
            let properties = entry["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? entry["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any] ?? entry["connectionProperties"] as? [String: Any] ?? [:]
            let device = properties["device"] as? [String: Any] ?? entry["deviceProperties"] as? [String: Any] ?? [:]
            guard let udid = hardware["udid"] as? String ?? entry["identifier"] as? String else { return nil }
            let pairing = connection["pairingState"] as? String ?? "unknown"
            let state = connection["state"] as? String ?? ""
            return Device(udid: udid,
                          name: device["name"] as? String ?? hardware["marketingName"] as? String ?? udid,
                          model: hardware["marketingName"] as? String ?? hardware["productType"] as? String ?? "iPhone",
                          productType: hardware["productType"] as? String ?? "",
                          osVersion: device["osVersionNumber"] as? String ?? device["osBuild"] as? String,
                          isPhysical: (hardware["reality"] as? String ?? "physical") == "physical",
                          isPaired: pairing == "paired",
                          isConnected: state == "connected" || state == "available",
                          transport: connection["transportType"] as? String)
        }
        .sorted { ($0.isPhysical ? 0 : 1, $0.name) < ($1.isPhysical ? 0 : 1, $1.name) }
    }
}

/// Copies a built `.nxgame` folder into the phone's `Documents/.incoming/<uuid>/`, writing `.complete` last. The
/// phone imports only a folder that carries that marker, so a transfer cut in half is never imported. When a copy
/// fails, what already arrived is removed from the phone before the error is reported (`abandon`).
///
/// One `devicectl` call per top-level entry: a directory source goes recursively, which is how the engine's own
/// `push_romfs.sh` sends a few hundred thousand files in one go.
public final class DeviceTransfer: @unchecked Sendable {
    public struct Progress: Sendable {
        public var fraction: Double
        public var detail: String
    }

    /// Lets the queue stop a transfer: the devicectl copy under way is terminated, and the part already sent is
    /// marked for the phone to delete, as for any failed copy.
    public final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        public init() {}

        public func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        public var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    public let toolchain: Toolchain
    private let fileManager: FileManager

    public init(toolchain: Toolchain, fileManager: FileManager = .default) {
        self.toolchain = toolchain
        self.fileManager = fileManager
    }

    public struct Outcome: Sendable {
        public var remoteFolder: String
        public var entries: [String]
        public var bytes: Int64
    }

    @discardableResult
    public func transfer(package: URL, to device: Device, bundleID: String, control: Control = Control(),
                         onProgress: @escaping (Progress) -> Void = { _ in }) throws -> Outcome {
        guard device.canReceive else {
            throw NXPocketError(.deviceUnavailable, "\(device.name) is not a paired physical device")
        }
        let bundleID = try installedBundleID(on: device, matching: bundleID)
        let incoming = "\(GameLayout.incomingFolder)/\(UUID().uuidString)"
        let entries = try topLevel(of: package)
        guard !entries.isEmpty else {
            throw NXPocketError(.packageMissing, "the package is empty", path: package.path)
        }
        let total = max(entries.reduce(Int64(0)) { $0 + max($1.size, 1) }, 1)
        var sent: Int64 = 0
        defer { try? fileManager.removeItem(at: markerURL) }

        do {
            try copy(marker(), to: device, bundleID: bundleID, destination: "\(incoming)/.started", control: control)
            try send(entries, into: incoming, total: total, sent: &sent, to: device, bundleID: bundleID,
                     control: control, onProgress: onProgress)
            try copy(marker(), to: device, bundleID: bundleID, destination: "\(incoming)/\(GameLayout.completeMarker)",
                     control: control)
        } catch {
            // What already reached the phone is gigabytes that will never be imported: it is marked for NXPocket
            // there to delete before the failure is reported.
            let marked = abandon(incoming, on: device, bundleID: bundleID)
            throw Self.failure(error, partialCopyMarked: marked)
        }
        onProgress(Progress(fraction: 1, detail: "sent"))
        return Outcome(remoteFolder: incoming, entries: entries.map(\.name), bytes: sent)
    }

    private func send(_ entries: [Entry], into incoming: String, total: Int64, sent: inout Int64, to device: Device,
                      bundleID: String, control: Control, onProgress: @escaping (Progress) -> Void) throws {
        for entry in entries {
            let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            onProgress(Progress(fraction: Double(sent) / Double(total), detail: "\(entry.name) · \(size)"))
            // devicectl reports nothing while it copies, and romfs.img is nearly the whole package: the bar sat at 1%
            // for minutes. For a large entry the phone is asked how much of it has arrived, every few seconds: a file
            // grows in place, and a folder (a framework with 857 MB of shaders) fills file by file.
            let before = sent
            let watch: RemoteWatch? = entry.size < Self.watchThreshold ? nil
                : RemoteWatch(folder: "Documents/\(incoming)", name: entry.name, isDirectory: entry.isDirectory) { arrived, rate in
                    let done = min(arrived, entry.size)
                    let speed = rate.map { " · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))/s" } ?? ""
                    onProgress(Progress(fraction: Double(before + done) / Double(total),
                                        detail: "\(entry.name) · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(size)\(speed)"))
                }
            try copy(entry.url, to: device, bundleID: bundleID, destination: "\(incoming)/\(entry.name)", watch: watch,
                     control: control)
            sent += max(entry.size, 1)
        }
    }

    /// Leaves `.abandoned` in a transfer folder on the phone. NXPocket there deletes such a folder, with everything
    /// it holds, as soon as it looks (`GameImporter.cleanStaleIncoming`), and one that never got the marker after
    /// `GameLayout.incomingIdleLimit` without activity.
    ///
    /// Only the marker is copied. This used to empty the folder first with `devicectl device copy to
    /// --remove-existing-content true`, which empties the app's WHOLE data container, not the destination: measured
    /// on the iPhone on 2026-11-11, a file in Documents was gone and Library and SystemData were made anew. Every
    /// failed or cancelled send wiped the phone's games, saves and settings. False when the phone could not be reached.
    func abandon(_ incoming: String, on device: Device, bundleID: String) -> Bool {
        let marker = fileManager.temporaryDirectory.appendingPathComponent("nxpocket-abandoned-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: marker) }
        do {
            try Data("abandoned\n".utf8).write(to: marker)
            let arguments = Self.copyArguments(source: marker, device: device, bundleID: bundleID,
                                               destination: "\(incoming)/\(GameLayout.abandonedMarker)")
            return try ProcessRunner.capture(toolchain.xcrun, arguments, timeout: 60).status == 0
        } catch {
            return false
        }
    }

    /// The error a failed transfer reports: the cause, then what became of the part already sent.
    static func failure(_ error: Error, partialCopyMarked: Bool) -> NXPocketError {
        let cause = error as? NXPocketError ?? NXPocketError(.transferFailed, error.localizedDescription)
        let minutes = Int(GameLayout.incomingIdleLimit / 60)
        let aftermath = partialCopyMarked
            ? "NXPocket on the iPhone deletes the part already sent when it next opens"
            : "the part already sent is still on the iPhone: NXPocket removes it after \(minutes) minutes without activity"
        return NXPocketError(cause.code, "\(cause.detail) (\(aftermath))", path: cause.path)
    }

    /// `devicectl device copy to` into the app's `Documents`. Never with `--remove-existing-content`: that empties
    /// the app's whole data container (`abandon`).
    static func copyArguments(source: URL, device: Device, bundleID: String, destination: String) -> [String] {
        ["devicectl", "device", "copy", "to",
         "--device", device.udid,
         "--domain-type", "appDataContainer",
         "--domain-identifier", bundleID,
         "--source", source.path,
         "--destination", "Documents/\(destination)",
         "-q"]
    }

    struct Entry {
        var name: String
        var url: URL
        var size: Int64
        var isDirectory: Bool = false
    }

    /// Files above this are watched on the phone while they copy (`RemoteWatch`); below it a copy is quick enough.
    static let watchThreshold: Int64 = 64 << 20
    /// How often the phone is asked; each question takes about a second over USB.
    static let watchInterval: TimeInterval = 5

    /// One file being copied, and what to do with how much of it the phone already has.
    struct RemoteWatch {
        var folder: String
        var name: String
        var isDirectory: Bool = false
        var report: (_ arrived: Int64, _ bytesPerSecond: Double?) -> Void
    }

    /// The listing that tells how much of the watched entry arrived, and nothing more: for a file, the transfer
    /// folder's own entries (`--no-recurse`); for a folder, that folder alone. The whole transfer folder used to be
    /// listed, recursively, every 3 seconds, a framework's every file included.
    static func watchArguments(_ watch: RemoteWatch, device: Device, bundleID: String, output: URL) -> [String] {
        var arguments = ["devicectl", "device", "info", "files", "--device", device.udid,
                         "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                         "--subdirectory", watch.isDirectory ? "\(watch.folder)/\(watch.name)" : watch.folder]
        if !watch.isDirectory { arguments.append("--no-recurse") }
        return arguments + ["--json-output", output.path, "-q"]
    }

    /// The bytes of every file in a listing: a watched folder's, listed alone.
    static func totalSize(inFilesListing data: Data) -> Int64? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [[String: Any]] else { return nil }
        return files.reduce(Int64(0)) { total, file in
            let isDirectory = (file["resources"] as? [String: Any])?["isDirectory"] as? Bool ?? false
            let size = ((file["metadata"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? 0
            return isDirectory ? total : total + size
        }
    }

    /// A devicectl listing is the device's answer about one folder, not a file anyone could plant: it is read whole,
    /// but no larger than this.
    static let listingLimit: Int64 = 32 << 20

    /// The bytes of `relativePath` in `devicectl device info files --json-output` (`result.files[]`): the file's
    /// size, or the sum of the files under it for a folder (a folder's own entry counts nothing). Nil when it is not
    /// there yet.
    static func remoteSize(inFilesListing data: Data, relativePath: String) -> Int64? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [[String: Any]] else { return nil }
        var total: Int64 = 0
        var found = false
        for file in files {
            let path = file["relativePath"] as? String ?? file["name"] as? String ?? ""
            guard path == relativePath || path.hasPrefix(relativePath + "/") else { continue }
            found = true
            let isDirectory = (file["resources"] as? [String: Any])?["isDirectory"] as? Bool ?? false
            if !isDirectory, let metadata = file["metadata"] as? [String: Any], let size = metadata["size"] as? NSNumber {
                total += size.int64Value
            }
        }
        return found ? total : nil
    }

    private func remoteSize(of watch: RemoteWatch, on device: Device, bundleID: String) -> Int64? {
        let listing = fileManager.temporaryDirectory.appendingPathComponent("nxpocket-files-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: listing) }
        guard let result = try? ProcessRunner.capture(toolchain.xcrun,
                                                      Self.watchArguments(watch, device: device, bundleID: bundleID, output: listing),
                                                      timeout: 30),
              result.status == 0, let data = try? BoundedRead.data(at: listing, limit: Self.listingLimit) else { return nil }
        return watch.isDirectory ? Self.totalSize(inFilesListing: data) : Self.remoteSize(inFilesListing: data, relativePath: watch.name)
    }

    /// The package's own entries, `romfs.img` last so the framework lands first and the importer can fail early. The
    /// Finder's files are left out; one inside the framework still goes along with it (devicectl copies a folder
    /// whole), and the shell deletes it before checking the package.
    func topLevel(of package: URL) throws -> [Entry] {
        let names = (try? fileManager.contentsOfDirectory(atPath: package.path)) ?? []
        var entries: [Entry] = []
        for name in names.sorted() where !PackageScanner.isFinderMetadata(name) {
            let url = package.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let size = isDirectory.boolValue
                ? PackageWriter.size(of: url, fileManager: fileManager)
                : Int64((try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
            entries.append(Entry(name: name, url: url, size: size, isDirectory: isDirectory.boolValue))
        }
        return entries.sorted { ($0.name == "romfs.img" ? 1 : 0, $0.name) < ($1.name == "romfs.img" ? 1 : 0, $1.name) }
    }

    /// The bundle ID the app is installed under. SideStore and AltStore append the team to it
    /// (`dev.nxpocket.app.ABCDE12345`), so the plain one names no app on the phone and devicectl refuses the copy.
    /// The exact one wins; otherwise the single installed app whose ID is it plus a suffix.
    public func installedBundleID(on device: Device, matching bundleID: String) throws -> String {
        let listing = fileManager.temporaryDirectory.appendingPathComponent("nxpocket-apps-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: listing) }
        let result = try ProcessRunner.capture(toolchain.xcrun,
                                               ["devicectl", "device", "info", "apps", "--device", device.udid,
                                                "--json-output", listing.path, "-q"], timeout: 120)
        guard result.status == 0, let data = try? BoundedRead.data(at: listing, limit: Self.listingLimit) else {
            // Without a listing the configured ID is all there is; devicectl will say if it is wrong.
            return bundleID
        }
        let installed = Self.bundleIDs(inAppsListing: data)
        return try Self.resolve(bundleID, among: installed, device: device.name)
    }

    static func bundleIDs(inAppsListing data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else { return [] }
        return apps.compactMap { $0["bundleIdentifier"] as? String }
    }

    static func resolve(_ bundleID: String, among installed: [String], device: String) throws -> String {
        if installed.isEmpty || installed.contains(bundleID) { return bundleID }
        let suffixed = installed.filter { $0.hasPrefix(bundleID + ".") }
        if suffixed.count == 1 { return suffixed[0] }
        if suffixed.isEmpty {
            throw NXPocketError(.transferFailed, "NXPocket (\(bundleID)) is not installed on \(device)")
        }
        throw NXPocketError(.transferFailed, "\(device) has several copies of NXPocket (\(suffixed.joined(separator: ", "))): "
                                + "set the one to send to in Settings → iPhone app bundle ID")
    }

    private var markerURL: URL { fileManager.temporaryDirectory.appendingPathComponent("nxpocket-complete") }

    private func marker() throws -> URL {
        try Data("complete\n".utf8).write(to: markerURL)
        return markerURL
    }

    private func copy(_ source: URL, to device: Device, bundleID: String, destination: String,
                      watch: RemoteWatch? = nil, control: Control) throws {
        if control.isCancelled { throw NXPocketError(.cancelled, "send cancelled") }
        let arguments = Self.copyArguments(source: source, device: device, bundleID: bundleID, destination: destination)
        // Started and waited on here rather than with ProcessRunner.capture, so the phone can be asked how much has
        // arrived while devicectl is still copying, and so a cancel can stop it.
        let runner = ProcessRunner(executable: toolchain.xcrun, arguments: arguments)
        try runner.start()
        let started = Date()
        let deadline = started.addingTimeInterval(7200)
        var nextCheck = started.addingTimeInterval(Self.watchInterval)
        while runner.isRunning {
            if control.isCancelled {
                runner.cancel()
                _ = runner.waitUntilExit()
                throw NXPocketError(.cancelled, "send cancelled")
            }
            if Date() >= deadline {
                runner.cancel()
                throw NXPocketError(.transferFailed, "devicectl did not finish copying \(source.lastPathComponent) within 2 hours")
            }
            if let watch, Date() >= nextCheck {
                if let arrived = remoteSize(of: watch, on: device, bundleID: bundleID), runner.isRunning {
                    let elapsed = Date().timeIntervalSince(started)
                    watch.report(arrived, elapsed > 1 && arrived > 0 ? Double(arrived) / elapsed : nil)
                }
                nextCheck = Date().addingTimeInterval(Self.watchInterval)
            }
            usleep(100_000)
        }
        let result = runner.waitUntilExit()
        guard result.status == 0 else {
            throw NXPocketError(.transferFailed,
                                result.lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                                    ?? "devicectl exited with \(result.status)")
        }
    }
}
