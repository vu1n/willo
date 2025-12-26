import Foundation
import Security
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// Manages SSH keypair generation and storage in iOS Keychain
///
/// Generates Ed25519 keypairs for passwordless SSH authentication.
/// Private keys are stored securely in the iOS Keychain.
final class SSHKeyManager {
    static let shared = SSHKeyManager()

    private let keyTag = "com.willo.ssh.ed25519"
    private let publicKeyDefaultsKey = "WilloSSHPublicKey"

    private init() {}

    // MARK: - Public API

    /// Check if we have an SSH keypair
    var hasKeyPair: Bool {
        getPrivateKey() != nil
    }

    /// Get the public key in OpenSSH format (ssh-ed25519 AAAA... user@willo)
    var publicKeyOpenSSH: String? {
        guard let publicKeyData = getPublicKeyData() else { return nil }
        return formatAsOpenSSH(publicKeyData)
    }

    /// Generate a new Ed25519 keypair
    /// - Returns: The public key in OpenSSH format
    @discardableResult
    func generateKeyPair() throws -> String {
        // Delete existing key if present
        deleteKeyPair()

        // Generate Ed25519 key using CryptoKit
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        // Store private key in Keychain
        try storePrivateKey(privateKey.rawRepresentation)

        // Store public key in UserDefaults (not sensitive)
        let publicKeyData = publicKey.rawRepresentation
        UserDefaults.standard.set(publicKeyData, forKey: publicKeyDefaultsKey)

        // Return OpenSSH format
        return formatAsOpenSSH(publicKeyData)
    }

    /// Delete the keypair
    func deleteKeyPair() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: publicKeyDefaultsKey)
    }

    /// Get the private key data (for SSH authentication)
    func getPrivateKeyData() -> Data? {
        getPrivateKey()
    }

    // MARK: - Private Methods

    private func getPrivateKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private func storePrivateKey(_ keyData: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SSHKeyError.keychainError(status)
        }
    }

    private func getPublicKeyData() -> Data? {
        UserDefaults.standard.data(forKey: publicKeyDefaultsKey)
    }

    /// Format Ed25519 public key as OpenSSH format
    /// ssh-ed25519 AAAA...base64... comment
    private func formatAsOpenSSH(_ rawPublicKey: Data) -> String {
        // OpenSSH format: "ssh-ed25519" length-prefixed string + raw key data
        var blob = Data()

        // Add key type string with length prefix
        let keyType = "ssh-ed25519"
        let keyTypeData = keyType.data(using: .utf8)!
        blob.append(contentsOf: UInt32(keyTypeData.count).bigEndianBytes)
        blob.append(keyTypeData)

        // Add public key with length prefix
        blob.append(contentsOf: UInt32(rawPublicKey.count).bigEndianBytes)
        blob.append(rawPublicKey)

        // Base64 encode
        let base64 = blob.base64EncodedString()

        // Get device name for comment
        #if os(iOS)
        let comment = "willo@\(UIDevice.current.name.replacingOccurrences(of: " ", with: "-"))"
        #else
        let comment = "willo@device"
        #endif

        return "ssh-ed25519 \(base64) \(comment)"
    }
}

// MARK: - Errors

enum SSHKeyError: LocalizedError {
    case keychainError(OSStatus)
    case keyNotFound
    case invalidKeyFormat

    var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .keyNotFound:
            return "SSH key not found"
        case .invalidKeyFormat:
            return "Invalid key format"
        }
    }
}

// MARK: - Helpers

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        return [
            UInt8((be >> 24) & 0xFF),
            UInt8((be >> 16) & 0xFF),
            UInt8((be >> 8) & 0xFF),
            UInt8(be & 0xFF)
        ]
    }
}
