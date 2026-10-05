import CryptoKit
import Foundation

/// The signed-in Claude Code session on this Mac: one keychain entry holding the
/// OAuth tokens, and one JSON file holding everything else.
///
/// Switching accounts is entirely a matter of swapping that pair, which is why
/// this type is the only place that needs to know where either half lives.
public struct Session: Sendable {

    /// Service name Claude Code files its tokens under, when nothing has moved
    /// its configuration directory.
    public static let credentialService = "Claude Code-credentials"

    /// What Claude Code falls back to as the keychain account when the login
    /// name is not something it is willing to put there.
    static let fallbackAccount = "claude-code-user"

    public let credentials: SecretAddress
    public let settingsURL: URL

    public init(credentials: SecretAddress, settingsURL: URL) {
        self.credentials = credentials
        self.settingsURL = settingsURL
    }

    /// The session belonging to whoever is logged into the Mac.
    ///
    /// Worked out the way Claude Code itself works it out, because the only
    /// session worth finding is the one it will read:
    ///
    /// - The settings file is `~/.claude.json`. A `CLAUDE_CONFIG_DIR` moves it to
    ///   `$CLAUDE_CONFIG_DIR/.claude.json`, and a pre-1.0 `.config.json` in the
    ///   configuration directory takes precedence over both.
    /// - The tokens are under `Claude Code-credentials`. A `CLAUDE_CONFIG_DIR`
    ///   moves them to `Claude Code-credentials-` plus the first eight hex digits
    ///   of the SHA-256 of that directory, so that two configurations never share
    ///   a sign-in.
    ///
    /// `~/.claude/.claude.json` is not the live file on a default install. It is
    /// what a Claude Code started with `CLAUDE_CONFIG_DIR=~/.claude` writes, and
    /// other tools do exactly that, leaving behind a file full of caches with no
    /// account in it. Preferring it whenever it existed is what made a signed-in
    /// Mac look signed out.
    ///
    /// An app opened from the Finder does not inherit the shell's environment,
    /// so a `CLAUDE_CONFIG_DIR` set in `.zshrc` is invisible here. The candidates
    /// are therefore tried in order and the first one that names an account wins;
    /// if none does, the one Claude Code would use is returned, so that a fresh
    /// sign-in lands where it is expected.
    public static func current(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        user: String = NSUserName(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Session {
        let account = keychainAccount(environment: environment, user: user)
        let defaultDirectory = home.appendingPathComponent(".claude").path

        var candidates: [Session] = []
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            candidates.append(located(configDirectory: override, overridden: true,
                                      home: home, account: account, fileManager: fileManager))
        }
        candidates.append(located(configDirectory: defaultDirectory, overridden: false,
                                  home: home, account: account, fileManager: fileManager))
        // The one directory someone is likely to have pointed `CLAUDE_CONFIG_DIR`
        // at in a shell this app cannot see.
        candidates.append(located(configDirectory: defaultDirectory, overridden: true,
                                  home: home, account: account, fileManager: fileManager))

        return candidates.first { $0.isSignedIn(fileManager: fileManager) } ?? candidates[0]
    }

    /// Where one configuration directory keeps its session.
    ///
    /// `overridden` says whether that directory arrived through
    /// `CLAUDE_CONFIG_DIR`, which is what moves both the settings file and the
    /// keychain entry away from their defaults.
    static func located(configDirectory: String,
                        overridden: Bool,
                        home: URL,
                        account: String,
                        fileManager: FileManager) -> Session {
        let directory = URL(fileURLWithPath: configDirectory)
        let preOne = directory.appendingPathComponent(".config.json")
        let settings = fileManager.fileExists(atPath: preOne.path)
            ? preOne
            : (overridden ? directory : home).appendingPathComponent(".claude.json")

        let service = overridden
            ? "\(credentialService)-\(configDirectoryHash(configDirectory))"
            : credentialService

        return Session(credentials: SecretAddress(service: service, account: account),
                       settingsURL: settings)
    }

    /// The suffix Claude Code gives a relocated configuration's keychain entry:
    /// eight lowercase hex digits of the SHA-256 of the directory, NFC first.
    static func configDirectoryHash(_ directory: String) -> String {
        let digest = SHA256.hash(data: Data(directory.precomposedStringWithCanonicalMapping.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    /// The keychain account Claude Code files its tokens under: `$USER`, else
    /// the login name, and a fixed stand-in if either holds anything but
    /// letters, digits, dots, underscores and hyphens.
    static func keychainAccount(environment: [String: String], user: String) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? user
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
            return fallbackAccount
        }
        return name
    }

    private func isSignedIn(fileManager: FileManager) -> Bool {
        guard let data = fileManager.contents(atPath: settingsURL.path) else { return false }
        return SessionSettings(raw: data).isSignedIn
    }
}

/// The parts of Claude Code's settings file Janus reads.
///
/// Parsed loosely on purpose. The file belongs to another program and gains keys
/// between releases; anything unrecognised is left alone and written back untouched.
public struct SessionSettings {

    public let raw: Data

    public init(raw: Data) { self.raw = raw }

    private var root: [String: Any]? {
        try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
    }

    private var account: [String: Any]? {
        root?["oauthAccount"] as? [String: Any]
    }

    /// Email of the signed-in account, when the file records one.
    public var email: String? {
        guard let value = account?["emailAddress"] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Claude Code's own account identifier, stable across sign-ins.
    public var accountID: String? {
        account?["accountUuid"] as? String
    }

    /// Plan limits as Claude Code last measured them. Absent until the account has
    /// been used at least once.
    public var usage: Usage? {
        guard let cached = root?["cachedUsageUtilization"] as? [String: Any] else { return nil }
        return Usage(cached)
    }

    /// True when the file parses and names an account, which is the bar for
    /// treating it as a session worth saving.
    public var isSignedIn: Bool { email != nil }

    /// The same file with a fresh set of figures written into it, under the key
    /// and in the shape Claude Code uses.
    ///
    /// So that a reading fetched over the network outlives the app being quit,
    /// and so that the account it belongs to starts its next session with a cache
    /// that is not months old. Everything else in the file is left as it was.
    public func recording(_ limits: [String: Any], at moment: Date) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        var cached: [String: Any] = [
            // Whole milliseconds, which is what Claude Code writes here and what
            // it reads back. A fraction of one would very likely be tolerated;
            // matching the file's own convention costs nothing and assumes less.
            "fetchedAtMs": (moment.timeIntervalSince1970 * 1000).rounded(),
            "utilization": limits
        ]
        if let accountID { cached["accountUuid"] = accountID }
        root["cachedUsageUtilization"] = cached

        return try? JSONSerialization.data(withJSONObject: root)
    }
}
