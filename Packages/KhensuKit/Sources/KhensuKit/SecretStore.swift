// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

/// Small named secrets (wrapped keys, key handles). Never synced: the keychain
/// implementation uses `ThisDeviceOnly` and the data-protection keychain.
public protocol SecretStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ value: Data) throws
    func delete(_ name: String) throws
}

public struct KeychainStore: SecretStore {
    public let service: String
    public let accessGroup: String?

    /// `accessGroup` must be one of the app's keychain-access-groups (with the team prefix), or nil for the default.
    public init(service: String = "nu.khensu.ptah", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ name: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read(_ name: String) throws -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw KhensuError.keychain(status)
        }
    }

    public func write(_ name: String, _ value: Data) throws {
        try delete(name)
        var q = query(name)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KhensuError.keychain(status) }
    }

    public func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KhensuError.keychain(status) }
    }
}

/// In-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(_ name: String) throws -> Data? { lock.withLock { items[name] } }
    public func write(_ name: String, _ value: Data) throws { lock.withLock { items[name] = value } }
    public func delete(_ name: String) throws { _ = lock.withLock { items.removeValue(forKey: name) } }
}
