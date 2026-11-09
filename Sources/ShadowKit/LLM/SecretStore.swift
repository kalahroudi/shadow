// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Where API keys live (R5): the macOS Keychain in the app, an in-memory fake in tests. Nothing else may hold a key.
public protocol SecretStore: Sendable {
    func get(account: String) throws -> String?
    func set(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public extension SecretStore {
    func key(for kind: CloudKind) -> String? {
        guard let k = try? get(account: kind.keyAccount) else { return nil }
        return k.isEmpty ? nil : k
    }

    /// Trims pasted whitespace. An empty key removes the stored one.
    func saveKey(_ key: String, for kind: CloudKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try delete(account: kind.keyAccount) } else { try set(trimmed, account: kind.keyAccount) }
    }
}

/// Generic-password items in the login keychain, readable only on this Mac and never synced.
public struct KeychainStore: SecretStore {
    public static let defaultService = "Shadow language model keys"
    private let service: String

    public init(service: String = defaultService) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func fail(_ status: OSStatus) -> UserFacingError {
        UserFacingError("Couldn't access the macOS Keychain (error \(status)). Check that Shadow is allowed to use it.")
    }

    public func get(account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw fail(status) }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw fail(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw fail(status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw fail(status) }
    }
}
