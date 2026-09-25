import Foundation
import Security

/// Where a secret lives in the keychain. macOS keys generic passwords by the
/// service/account pair, so the two together are the whole address.
public struct SecretAddress: Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum SecretError: LocalizedError, Equatable {
    case notFound(SecretAddress)
    case accessDenied(SecretAddress)
    case unexpected(SecretAddress, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notFound(let address):
            return "Nothing is stored in the keychain for '\(address.service)'."
        case .accessDenied(let address):
            return "macOS refused access to the keychain entry for '\(address.service)'."
        case .unexpected(let address, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
            return "Keychain error on '\(address.service)': \(detail)"
        }
    }
}

/// Anywhere secrets can be kept.
///
/// The protocol exists so tests can run against memory: a test suite that writes
/// to the real login keychain would leave entries behind on whoever ran it.
public protocol SecretStore: AnyObject, Sendable {
    func read(_ address: SecretAddress) throws -> Data
    func write(_ payload: Data, to address: SecretAddress) throws
    func remove(_ address: SecretAddress) throws
    func contains(_ address: SecretAddress) -> Bool
}

/// The login keychain, reached through the Security framework.
public final class SystemKeychain: SecretStore {

    public init() {}

    private func baseQuery(_ address: SecretAddress) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: address.service,
            kSecAttrAccount as String: address.account
        ]
    }

    public func read(_ address: SecretAddress) throws -> Data {
        var query = baseQuery(address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw SecretError.unexpected(address, status) }
            return data
        case errSecItemNotFound:
            throw SecretError.notFound(address)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw SecretError.accessDenied(address)
        default:
            throw SecretError.unexpected(address, status)
        }
    }

    public func write(_ payload: Data, to address: SecretAddress) throws {
        let query = baseQuery(address)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: payload] as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = payload
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecretError.unexpected(address, added) }
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw SecretError.accessDenied(address)
        default:
            throw SecretError.unexpected(address, status)
        }
    }

    public func remove(_ address: SecretAddress) throws {
        let status = SecItemDelete(baseQuery(address) as CFDictionary)
        // Deleting something that is already gone is the outcome the caller wanted.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError.unexpected(address, status)
        }
    }

    /// Asks only whether the entry exists. Deliberately does not request the
    /// payload, so checking never raises a keychain permission prompt.
    public func contains(_ address: SecretAddress) -> Bool {
        var query = baseQuery(address)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// An in-memory stand-in, used by the test suite.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var entries: [SecretAddress: Data] = [:]
    private let lock = NSLock()

    public init(seed: [SecretAddress: Data] = [:]) { entries = seed }

    public func read(_ address: SecretAddress) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let payload = entries[address] else { throw SecretError.notFound(address) }
        return payload
    }

    public func write(_ payload: Data, to address: SecretAddress) throws {
        lock.lock(); defer { lock.unlock() }
        entries[address] = payload
    }

    public func remove(_ address: SecretAddress) throws {
        lock.lock(); defer { lock.unlock() }
        entries[address] = nil
    }

    public func contains(_ address: SecretAddress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[address] != nil
    }

    /// Every address currently holding something, for assertions in tests.
    public var addresses: Set<SecretAddress> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.keys)
    }
}
