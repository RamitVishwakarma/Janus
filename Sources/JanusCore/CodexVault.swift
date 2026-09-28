import Foundation

/// Where saved Codex accounts are kept: each account's whole `auth.json` in the
/// keychain, and the list of them in a JSON file beside Claude Code's.
///
/// The whole file goes in the keychain rather than being split the way a Claude
/// Code session is, because in Codex's case there is nothing to split off. The
/// tokens are most of the file, and a copy of them in a plain file would be a
/// second place for them to leak from.
public final class CodexVault: Sendable {

    /// Keychain service the saved sign-ins are filed under, one entry per account
    /// keyed by its UUID. Distinct from `Vault.keychainService` so that neither
    /// list can ever be mistaken for the other.
    public static let keychainService = "Janus Codex"

    public let root: URL
    private let secrets: SecretStore

    public init(root: URL = CodexVault.defaultRoot, secrets: SecretStore = SystemKeychain()) {
        self.root = root
        self.secrets = secrets
    }

    private var fileManager: FileManager { .default }

    public static var defaultRoot: URL {
        Vault.defaultRoot.appendingPathComponent("Codex", isDirectory: true)
    }

    private var rosterURL: URL { root.appendingPathComponent("roster.json") }

    func address(for id: UUID) -> SecretAddress {
        SecretAddress(service: CodexVault.keychainService, account: id.uuidString)
    }

    // MARK: - The roster

    public func loadRoster() throws -> Roster {
        guard let data = fileManager.contents(atPath: rosterURL.path) else { return Roster() }
        do {
            return try decoder.decode(Roster.self, from: data)
        } catch {
            throw VaultError.unreadableRoster(rosterURL)
        }
    }

    public func save(_ roster: Roster) throws {
        try prepareDirectory()
        let data = try encoder.encode(roster)
        try data.write(to: rosterURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rosterURL.path)
    }

    // MARK: - Saved sign-ins

    /// Asks only whether an entry exists, which never raises a keychain prompt.
    public func hasSession(for id: UUID) -> Bool {
        secrets.contains(address(for: id))
    }

    public func store(_ auth: CodexAuth, for id: UUID) throws {
        try secrets.write(auth.raw, to: address(for: id))
    }

    public func auth(for id: UUID) throws -> CodexAuth {
        let raw: Data
        do {
            raw = try secrets.read(address(for: id))
        } catch SecretError.notFound {
            throw VaultError.noSavedSession(id)
        }
        guard let parsed = CodexAuth(raw), parsed.isSignedIn else {
            throw VaultError.unreadableCredentials(id)
        }
        return parsed
    }

    /// Forgets an account's saved sign-in. Used when an account is removed.
    public func discard(for id: UUID) {
        try? secrets.remove(address(for: id))
    }

    // MARK: - Plumbing

    private func prepareDirectory() throws {
        guard !fileManager.fileExists(atPath: root.path) else { return }
        try fileManager.createDirectory(at: root,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
