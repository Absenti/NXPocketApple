import Foundation
import NXPocketKit
import NXPocketSFTP

/// A place games can be downloaded from, as the phone remembers it. Nothing secret is in it: the token a Mac issued and an
/// SFTP server's password or key are in the keychain, apart (`SourceStore.secret`).
public struct SourceRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case mac, sftp, web }

    public var id: String
    public var kind: Kind
    public var name: String
    public var host: String
    public var port: Int
    /// The key the source must present: the Mac's, or an SFTP server's host key. A key is public, so it is kept here.
    public var pin: String?
    public var user: String?
    public var folder: String?

    public init(id: String = UUID().uuidString, kind: Kind, name: String, host: String, port: Int, pin: String? = nil,
                user: String? = nil, folder: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.pin = pin
        self.user = user
        self.folder = folder
    }

    public var sftpConfig: SFTPConfig? {
        guard kind == .sftp, let user else { return nil }
        return SFTPConfig(host: host, port: port, user: user, hostKey: pin, folder: folder ?? "/")
    }

    /// A web library's address: kept in `folder`, the field that names where an SFTP server keeps its games.
    public var webURL: URL? { kind == .web ? folder.flatMap { WebSource.validated($0) } : nil }

    /// What a paused download is filed under (`DownloadJournal.sourceID`).
    public var sourceID: String? {
        switch kind {
        case .mac: return pin.map { PinnedHTTPSSource.sourceID(pin: $0) }
        case .sftp: return sftpConfig.map { SFTPSource.sourceID(for: $0) }
        case .web: return webURL.map { WebSource.sourceID(for: $0) }
        }
    }
}

/// The sources the player added. Their descriptions are kept in the app's preferences, their secrets in the keychain
/// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, as the certificate). When the keychain refuses, as it does under some
/// stores, a secret is kept for this run only and the screen says so: no secret is ever written to a file instead.
@MainActor
public final class SourceStore: ObservableObject {
    @Published public private(set) var records: [SourceRecord]
    /// Set when a secret could not be put in the keychain and lives in memory only.
    @Published public private(set) var secretsInMemoryOnly = false

    /// What is kept as the secret of a web library that has no token: the keychain does not keep an empty one.
    public static let noToken = "-"

    private var memory: [String: String] = [:]
    private let defaults: UserDefaults
    private static let key = "networkSources"
    private let keychain: SecretKeeper

    public init(defaults: UserDefaults = .standard, keychain: SecretKeeper = SystemKeychainSecrets()) {
        self.defaults = defaults
        self.keychain = keychain
        let decoded = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([SourceRecord].self, from: $0) }
        // An IPv4 address saved with the interface it was found on ("192.168.1.12%en0", as an earlier version stored it) is no
        // address a URL can use: the interface is dropped.
        records = (decoded ?? []).map { record in
            var record = record
            if let zone = record.host.firstIndex(of: "%"), record.host[..<zone].split(separator: ".").count == 4 {
                record.host = String(record.host[..<zone])
            }
            return record
        }
    }

    public func add(_ record: SourceRecord, secret: String) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.append(record) }
        keep(secret, for: record.id)
        save()
    }

    public func update(_ record: SourceRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        save()
    }

    public func remove(_ record: SourceRecord) {
        records.removeAll { $0.id == record.id }
        memory[record.id] = nil
        keychain.remove(account: record.id)
        save()
    }

    public func secret(for record: SourceRecord) -> String? {
        memory[record.id] ?? keychain.load(account: record.id)
    }

    /// The source to download from, or nil when its secret is missing (it was lost with the keychain, or never saved).
    public func source(for record: SourceRecord) -> PackageSource? {
        guard let secret = secret(for: record), !secret.isEmpty else { return nil }
        switch record.kind {
        case .mac:
            guard let pin = record.pin else { return nil }
            return PinnedHTTPSSource(PairedMac(host: record.host, port: record.port, pin: pin, token: secret, name: record.name))
        case .sftp:
            guard let config = record.sftpConfig, let credential = SFTPCredential.decode(secret) else { return nil }
            return SFTPSource(config: config, credential: credential)
        case .web:
            // The secret is the access token, or `SourceStore.noToken` when the address itself is the secret.
            guard let url = record.webURL else { return nil }
            return WebSource(baseURL: url, token: secret == Self.noToken ? nil : secret)
        }
    }

    private func keep(_ secret: String, for id: String) {
        do {
            try keychain.store(secret, account: id)
            memory[id] = nil
        } catch {
            memory[id] = secret
            secretsInMemoryOnly = true
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.key) }
    }
}

/// Where a source's secret is kept: the keychain, or a stand-in in tests.
public protocol SecretKeeper {
    func store(_ secret: String, account: String) throws
    func load(account: String) -> String?
    func remove(account: String)
}

public struct SystemKeychainSecrets: SecretKeeper {
    public init() {}
    public func store(_ secret: String, account: String) throws { try Keychain.store(Data(secret.utf8), account: account, service: .sources) }
    public func load(account: String) -> String? { Keychain.load(account: account, service: .sources).flatMap { String(data: $0, encoding: .utf8) } }
    public func remove(account: String) { Keychain.remove(account: account, service: .sources) }
}
