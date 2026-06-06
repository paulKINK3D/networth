import Foundation
import Security
import os

/// High-sensitivity persistent storage for the YNAB Personal Access Token.
/// Production impl uses the iCloud-synced Keychain so a future device swap is
/// zero-friction.
public protocol SecretStore: Sendable {
    func save(_ secret: String, for key: SecretKey) throws
    func load(_ key: SecretKey) throws -> String?
    func delete(_ key: SecretKey) throws
}

public struct SecretKey: Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let ynabPersonalAccessToken = SecretKey(rawValue: "ynab.personal_access_token")
}

public enum SecretStoreError: Error, Sendable {
    case unhandled(OSStatus)
    case invalidData
}

public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let synchronizable: Bool

    public init(service: String = "com.bluelava.me.networth", synchronizable: Bool = true) {
        self.service = service
        self.synchronizable = synchronizable
    }

    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "secret-store")

    public func save(_ secret: String, for key: SecretKey) throws {
        guard let data = secret.data(using: .utf8) else { throw SecretStoreError.invalidData }
        var attrs: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        if synchronizable {
            attrs[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }

        // Update if present, otherwise add.
        let query = attrs
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            attrs[kSecValueData as String] = data
            let addStatus = SecItemAdd(attrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.unhandled(addStatus)
            }
        default:
            throw SecretStoreError.unhandled(updateStatus)
        }
    }

    public func load(_ key: SecretKey) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String:  kCFBooleanTrue!,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.invalidData
            }
            return s
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.unhandled(status)
        }
    }

    public func delete(_ key: SecretKey) throws {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unhandled(status)
        }
    }
}

/// Test/preview implementation. Never use in production.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    public init(seed: [SecretKey: String] = [:]) {
        for (key, value) in seed { storage[key.rawValue] = value }
    }
    public func save(_ secret: String, for key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key.rawValue] = secret
    }
    public func load(_ key: SecretKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key.rawValue]
    }
    public func delete(_ key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key.rawValue] = nil
    }
}
