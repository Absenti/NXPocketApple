import CryptoKit
import Foundation
import NXPocketKit

/// A phone the player paired. The token itself is never kept: only its SHA-256, so the file of paired phones authenticates
/// nobody if it is read, and the name and dates are what the Settings list shows.
public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tokenHash: String
    public var pairedAt: Date
    public var lastSeen: Date
}

/// The paired phones, kept in a file only the player can read, and the one place that says whether a token is good.
public final class PairedDevices: @unchecked Sendable {
    /// A token unused for this long is dropped: a phone that was sold or lost a year ago stops being a way in.
    public static let idleLimit: TimeInterval = 90 * 24 * 3600
    public static let fileName = "paired.json"
    static let maxDevices = 32

    private let url: URL
    private let lock = NSLock()
    private var devices: [PairedDevice]
    private var lastSaved = Date.distantPast

    public init(folder: URL = ServerIdentity.standardFolder, now: Date = Date()) {
        url = folder.appendingPathComponent(Self.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = BoundedRead.dataIfPresent(at: url, limit: 1 << 20).flatMap { try? decoder.decode([PairedDevice].self, from: $0) } ?? []
        devices = stored.filter { now.timeIntervalSince($0.lastSeen) < Self.idleLimit }
    }

    public var all: [PairedDevice] { lock.withLock { devices.sorted { $0.pairedAt < $1.pairedAt } } }

    /// Pairs a phone: returns its new device and the token, which is shown to the phone once and then forgotten.
    public func add(name: String, now: Date = Date()) throws -> (device: PairedDevice, token: String) {
        var generator = SystemRandomNumberGenerator()
        let token = FileDigest.hex((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let clean = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(PairingProof.maxNameLength))
        let device = PairedDevice(id: UUID().uuidString, name: clean.isEmpty ? "iPhone" : clean, tokenHash: Self.hash(token),
                                  pairedAt: now, lastSeen: now)
        try lock.withLock {
            // The oldest goes before a 33rd is added: a list nobody reads grows only by being attacked.
            if devices.count >= Self.maxDevices, let oldest = devices.min(by: { $0.lastSeen < $1.lastSeen })?.id {
                devices.removeAll { $0.id == oldest }
            }
            devices.append(device)
            try save()
        }
        return (device, token)
    }

    /// The phone a token belongs to, or nil. The token is hashed before it is looked at, so what is compared is the same
    /// length whatever was sent.
    public func authenticate(_ token: String, now: Date = Date()) -> PairedDevice? {
        guard token.count == 64 else { return nil }
        let hash = Self.hash(token)
        return lock.withLock {
            guard let index = devices.firstIndex(where: { $0.tokenHash == hash }) else { return nil }
            guard now.timeIntervalSince(devices[index].lastSeen) < Self.idleLimit else {
                devices.remove(at: index)
                try? save()
                return nil
            }
            devices[index].lastSeen = now
            // A request every few milliseconds must not rewrite a file every few milliseconds.
            if now.timeIntervalSince(lastSaved) > 300 { try? save() }
            return devices[index]
        }
    }

    public func contains(id: String) -> Bool { lock.withLock { devices.contains { $0.id == id } } }

    public func device(id: String) -> PairedDevice? { lock.withLock { devices.first { $0.id == id } } }

    @discardableResult
    public func revoke(id: String) -> PairedDevice? {
        lock.withLock {
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return nil }
            let removed = devices.remove(at: index)
            try? save()
            return removed
        }
    }

    public func removeAll() {
        lock.withLock {
            devices.removeAll()
            try? save()
        }
    }

    static func hash(_ token: String) -> String { FileDigest.sha256(of: Data(token.utf8)) }

    /// Called with the lock held.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(devices)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw NXPocketError(.transferFailed, "the list of paired iPhones could not be saved") }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw NXPocketError(.transferFailed, "the list of paired iPhones could not be saved") }
        lastSaved = Date()
    }
}
