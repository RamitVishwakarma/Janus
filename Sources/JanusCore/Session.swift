import Foundation

/// The signed-in Claude Code session on this Mac: one keychain entry holding the
/// OAuth tokens, and one JSON file holding everything else.
///
/// Switching accounts is entirely a matter of swapping that pair, which is why
/// this type is the only place that needs to know where either half lives.
public struct Session: Sendable {

    /// Service name Claude Code files its tokens under.
    public static let credentialService = "Claude Code-credentials"

    public let credentials: SecretAddress
    public let settingsURL: URL

    public init(credentials: SecretAddress, settingsURL: URL) {
        self.credentials = credentials
        self.settingsURL = settingsURL
    }

    /// The session belonging to whoever is logged into the Mac.
    ///
    /// The settings file sits inside `~/.claude` on newer installs and directly in
    /// the home directory on older ones; whichever exists is the live one, and a
    /// fresh install that has neither gets the current default.
    ///
    /// Both can exist at once: a Claude Code started with `CLAUDE_CONFIG_DIR=~/.claude`,
    /// for one, leaves a stub in `~/.claude` that never records a sign-in, while the
    /// real session carries on in the home directory. Existing
    /// is therefore not enough: the file naming an account wins, and the order
    /// above only breaks a tie.
    public static func current(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        user: String = NSUserName(),
        fileManager: FileManager = .default
    ) -> Session {
        let nested = home.appendingPathComponent(".claude/.claude.json")
        let legacy = home.appendingPathComponent(".claude.json")
        let existing = [nested, legacy].filter { fileManager.fileExists(atPath: $0.path) }
        let signedIn = existing.first { url in
            fileManager.contents(atPath: url.path).map { SessionSettings(raw: $0).isSignedIn } ?? false
        }
        let settings = signedIn ?? existing.first ?? legacy

        return Session(
            credentials: SecretAddress(service: credentialService, account: user),
            settingsURL: settings
        )
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
