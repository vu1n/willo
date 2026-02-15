import Foundation
import Security

/// Secure credential storage using iOS Keychain.
///
/// Stores passwords with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// so they never leave the device (not in backups or iCloud sync).
final class CredentialStore {
    static let shared = CredentialStore()

    private let service = "com.willo.credentials"

    private init() {}

    // MARK: - Password Storage

    /// Store a password for a server profile
    func storePassword(_ password: String, forProfileId profileId: UUID) throws {
        guard let data = password.data(using: .utf8) else { return }
        let account = keychainKey(for: profileId)

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainError(status)
        }
    }

    /// Retrieve a password for a server profile
    func retrievePassword(forProfileId profileId: UUID) -> String? {
        let account = keychainKey(for: profileId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a password for a server profile
    func deletePassword(forProfileId profileId: UUID) {
        let account = keychainKey(for: profileId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    private func keychainKey(for profileId: UUID) -> String {
        "password.\(profileId.uuidString)"
    }
}

enum CredentialStoreError: LocalizedError {
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}
