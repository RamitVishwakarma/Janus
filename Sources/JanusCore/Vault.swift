import Foundation

/// Where saved accounts are kept: tokens in the keychain, everything else in a
/// folder of JSON under Application Support.
///
/// The split is not arbitrary. Credentials belong somewhere macOS encrypts and
/// locks with the login keychain; the settings file is large, boring and easier to
/// inspect and back up as a plain file.
public final class Vault: Sendable {

    /// Keychain service the saved tokens are filed under. Each account is a
    /// separate entry keyed by its UUID.
    public static let keychainService = "Janus"

    public let root: URL
    private let secrets: SecretStore

    public init(root: URL = Vault.defaultRoot, secrets: SecretStore = SystemKeychain()) {
        self.root = root
        self.secrets = secrets
    }

    private var fileManager: FileManager { .default }

    public static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Janus", isDirectory: true)
    }

    private var rosterURL: URL { root.appendingPathComponent("roster.json") }
    private var sessionsDirectory: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    func settingsURL(for id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    func credentialAddress(for id: UUID) -> SecretAddress {
        SecretAddress(service: Vault.keychainService, account: id.uuidString)
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
        try prepareDirectories()
        let data = try encoder.encode(roster)
        try data.write(to: rosterURL, options: .atomic)
        restrict(rosterURL)
    }

    // MARK: - Saved sessions

    public func hasSession(for id: UUID) -> Bool {
        secrets.contains(credentialAddress(for: id))
            && fileManager.fileExists(atPath: settingsURL(for: id).path)
    }

    /// Writes a session into the account's slot, replacing whatever was there.
    public func store(_ session: StoredSession, for id: UUID) throws {
        try prepareDirectories()
        try secrets.write(session.credentials, to: credentialAddress(for: id))

        let destination = settingsURL(for: id)
        try session.settings.write(to: destination, options: .atomic)
        restrict(destination)
    }

    /// The saved settings file on its own.
    ///
    /// Separate from `session(for:)` because reading it touches no secrets, and so
    /// can never raise a keychain prompt, which matters when the interface reads
    /// every account's figures each time it refreshes.
    public func storedSettings(for id: UUID) -> Data? {
        fileManager.contents(atPath: settingsURL(for: id).path)
    }

    /// Replaces the settings half of a saved session and leaves the tokens alone.
    ///
    /// Touches no secrets, which is what makes it something a refresh can do: an
    /// account's recorded figures can be brought up to date without a keychain
    /// prompt. A slot that does not exist yet is left alone rather than created,
    /// since settings without credentials is not a session anything can restore.
    public func refreshStoredSettings(_ settings: Data, for id: UUID) throws {
        let destination = settingsURL(for: id)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        try settings.write(to: destination, options: .atomic)
        restrict(destination)
    }

    public func session(for id: UUID) throws -> StoredSession {
        let settings = settingsURL(for: id)
        guard let contents = fileManager.contents(atPath: settings.path) else {
            throw VaultError.noSavedSession(id)
        }
        return StoredSession(credentials: try secrets.read(credentialAddress(for: id)),
                             settings: contents)
    }

    /// Forgets an account's stored halves. Used when an account is removed.
    public func discardSession(for id: UUID) {
        try? secrets.remove(credentialAddress(for: id))
        try? fileManager.removeItem(at: settingsURL(for: id))
    }

    /// Keychain entries left behind by accounts no longer on the roster, from a
    /// removal that failed halfway or a roster restored from an older backup.
    public func strandedSettingsFiles(roster: Roster) -> [URL] {
        let known = Set(roster.profiles.map { $0.id.uuidString + ".json" })
        let files = (try? fileManager.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        return files
            .filter { $0.hasSuffix(".json") && !known.contains($0) }
            .map { sessionsDirectory.appendingPathComponent($0) }
    }

    // MARK: - Plumbing

    private func prepareDirectories() throws {
        for directory in [root, sessionsDirectory] {
            guard !fileManager.fileExists(atPath: directory.path) else { continue }
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
    }

    /// Saved settings carry an account's project history, so they are readable by
    /// their owner and nobody else.
    private func restrict(_ url: URL) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

/// A session as it sits in storage: the token blob and the settings file.
public struct StoredSession: Equatable {
    public let credentials: Data
    public let settings: Data

    public init(credentials: Data, settings: Data) {
        self.credentials = credentials
        self.settings = settings
    }
}

public enum VaultError: LocalizedError, Equatable {
    case unreadableRoster(URL)
    case noSavedSession(UUID)

    public var errorDescription: String? {
        switch self {
        case .unreadableRoster(let url):
            return "The account list at \(url.path) could not be read."
        case .noSavedSession:
            return "This account has no saved session. Sign in as it and add it again."
        }
    }
}
