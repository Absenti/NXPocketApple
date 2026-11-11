import Foundation
import NXPocketKit
import Security

/// The app's keychain: the certificate that signs a game. Nothing here is ever
/// written to a file. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` keeps it off backups and off other devices.
public enum Keychain {
    public enum Service: String {
        case certificate = "dev.nxpocket.certificate"
    }

    /// The .p12 and its password together, in one item: one write replaces both or neither.
    public static let identityAccount = "signing.identity"
    /// Where earlier versions kept them, as two items; read when the combined one is missing, removed once it is written.
    public static let p12Account = "signing.p12"
    public static let passphraseAccount = "signing.passphrase"

    /// Replaces the item in place, or adds it when there is none: a refused write leaves the previous value as it was,
    /// where deleting first and adding after lost it. A refusal throws `KeychainRefusal` with the system's status.
    public static func store(_ data: Data, account: String, service: Service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: account
        ]
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainRefusal(status: status, account: account) }
    }

    public static func load(account: String, service: Service) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    public static func remove(account: String, service: Service) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    public static func removeAll() {
        remove(account: identityAccount, service: .certificate)
        remove(account: p12Account, service: .certificate)
        remove(account: passphraseAccount, service: .certificate)
    }

    public static func has(account: String, service: Service) -> Bool {
        load(account: account, service: service) != nil
    }
}
