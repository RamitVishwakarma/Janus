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
    /// The `security` tool came back with a status nothing here knows how to
    /// phrase. The number is its exit code, which is the low byte of the
    /// OSStatus underneath.
    case unexpected(SecretAddress, Int32)

    public var errorDescription: String? {
        switch self {
        case .notFound(let address):
            return "Nothing is stored in the keychain for '\(address.service)'."
        case .accessDenied(let address):
            return "macOS refused access to the keychain entry for '\(address.service)'."
        case .unexpected(let address, let status):
            return "The keychain would not give up '\(address.service)' (error \(status))."
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

/// The login keychain, reached by running `/usr/bin/security` rather than by
/// calling the Security framework directly.
///
/// Going the long way round is the entire point, and it is the fix for the
/// password prompts.
///
/// Since macOS Sierra every keychain entry carries a partition list naming the
/// code allowed to open it without asking, and macOS fills that list in with the
/// code signature of whichever program created the entry. An entry Janus creates
/// is therefore partitioned to Janus alone — which locks Claude Code out of its
/// own tokens, because Claude Code reaches them by running `security`, and puts
/// a login-password prompt in front of it every single time. An entry `security`
/// creates is partitioned to `apple-tool:` instead, which is exactly what Claude
/// Code writes for itself and what everything on the Mac already expects.
///
/// It cuts the other way too. A trusted-application entry is matched on code
/// signature, and Janus is signed ad-hoc, so its signature changes with every
/// build. Reading directly would mean a fresh prompt after every update, for
/// every account. Read through `security` and the identity being checked is
/// always the same one, whatever Janus happens to be today.
public final class SystemKeychain: SecretStore {

    static let tool = "/usr/bin/security"

    public init() {}

    public func read(_ address: SecretAddress) throws -> Data {
        let result = try run(["find-generic-password", "-w",
                              "-s", address.service, "-a", address.account], at: address)
        return Self.decode(result.output)
    }

    /// Replaces the entry, and in doing so puts its partition list back to the
    /// one Claude Code expects.
    ///
    /// Deleted and written again rather than updated, because an update leaves
    /// the partition list alone, and an entry an older build of Janus created
    /// under its own signature is precisely the thing that needs mending.
    /// Deleting requires no permission of its own, so it cannot raise a prompt.
    public func write(_ payload: Data, to address: SecretAddress) throws {
        try remove(address)

        // Hex on the command line, which is not the way anyone would choose to
        // pass a token. `security` will read one from standard input instead,
        // but it stops at 128 bytes, and a Claude Code session is four times
        // that, so the choice is between this and a silently truncated token.
        // It is also what Claude Code does to write the entry in the first
        // place. `ps` shows a process's arguments to other processes belonging
        // to the same user and to root, and to nobody else, for as long as the
        // one-shot `security` call lives.
        try run(["add-generic-password",
                 "-a", address.account,
                 "-s", address.service,
                 "-l", address.service,
                 "-X", Self.hex(payload)],
                at: address)
    }

    public func remove(_ address: SecretAddress) throws {
        do {
            try run(["delete-generic-password", "-s", address.service, "-a", address.account],
                    at: address)
        } catch SecretError.notFound {
            // Deleting something already gone is the outcome the caller wanted.
        }
    }

    /// Asks only whether the entry exists.
    ///
    /// The one operation still made through the framework: it never asks for the
    /// payload, so it cannot raise a prompt whoever is asking, and the interface
    /// does it for every account on every refresh.
    public func contains(_ address: SecretAddress) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: address.service,
            kSecAttrAccount as String: address.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Running the tool

    @discardableResult
    private func run(_ arguments: [String], at address: SecretAddress) throws -> Command.Result {
        guard let result = try? Command.run(Self.tool, arguments) else {
            throw SecretError.unexpected(address, -1)
        }
        guard result.succeeded else { throw Self.error(forExit: result.status, at: address) }
        return result
    }

    /// `security` exits with the low byte of the OSStatus it failed on, so the
    /// codes worth naming are the ones those statuses reduce to.
    static func error(forExit status: Int32, at address: SecretAddress) -> SecretError {
        switch status {
        case 44:            return .notFound(address)         // errSecItemNotFound
        case 36, 51, 128:   return .accessDenied(address)     // no interaction, auth failed, cancelled
        default:            return .unexpected(address, status)
        }
    }

    // MARK: - Payloads

    /// `security -w` prints the payload verbatim when every byte of it is
    /// printable ASCII, and as lowercase hex when any byte is not.
    ///
    /// The two are told apart by looking, which is safe for what Janus stores:
    /// the JSON blob Claude Code keeps its tokens in always carries braces and
    /// quotes, so a line of nothing but hex digits can only be the encoded form.
    static func decode(_ output: String) -> Data {
        let text = output.hasSuffix("\n") ? String(output.dropLast()) : output
        let hexDigits = Set("0123456789abcdef")

        guard !text.isEmpty, text.count.isMultiple(of: 2), text.allSatisfy(hexDigits.contains)
        else { return Data(text.utf8) }

        var bytes = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return Data(text.utf8) }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func hex(_ payload: Data) -> String {
        payload.map { String(format: "%02x", $0) }.joined()
    }
}

/// An in-memory stand-in, used by the test suite.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var entries: [SecretAddress: Data] = [:]
    private var refused: Set<SecretAddress> = []
    private let lock = NSLock()

    public init(seed: [SecretAddress: Data] = [:]) { entries = seed }

    /// Makes reading an address fail the way macOS does when its prompt is
    /// declined. Writing still works, which is not a contrivance: an entry is
    /// replaced by deleting and adding it, and neither step needs permission to
    /// read what was there.
    public func refuseReads(of address: SecretAddress) {
        lock.lock(); defer { lock.unlock() }
        refused.insert(address)
    }

    /// Lets reads through again, so a test can look at what survived a refusal.
    public func allowReads(of address: SecretAddress) {
        lock.lock(); defer { lock.unlock() }
        refused.remove(address)
    }

    public func read(_ address: SecretAddress) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if refused.contains(address) { throw SecretError.accessDenied(address) }
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
