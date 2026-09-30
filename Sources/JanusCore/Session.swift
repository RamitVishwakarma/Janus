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
    public static func current(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        user: String = NSUserName(),
        fileManager: FileManager = .default,
        secrets: SecretStore = SystemKeychain()
    ) -> Session {
        let nested = home.appendingPathComponent(".claude/.claude.json")
        let legacy = home.appendingPathComponent(".claude.json")

        // A Mac that has run more than one version of Claude Code can hold both
        // files, and only one of them names the account — the other is a stale
        // shell left behind by an upgrade. Location alone is not enough to tell
        // them apart, so prefer whichever file actually records a signed-in
        // account, and fall back to the newer-install-wins rule only when
        // neither does (a fresh install, or one signed out).
        let settings = [nested, legacy].first { namesAccount($0, fileManager: fileManager) }
            ?? (fileManager.fileExists(atPath: nested.path) ? nested : legacy)

        // Claude Code has filed its tokens under the login name in some versions
        // and under the service name itself in others. The account is half of a
        // keychain entry's address, so guessing it wrong is indistinguishable
        // from being signed out. Ask the keychain which address is really there;
        // when nothing is, fall back to what current Claude Code writes, so the
        // entry a later sign-in creates is the one that gets found.
        let account = [user, credentialService].first {
            secrets.contains(SecretAddress(service: credentialService, account: $0))
        } ?? credentialService

        return Session(
            credentials: SecretAddress(service: credentialService, account: account),
            settingsURL: settings
        )
    }

    /// Whether a settings file both exists and records a signed-in account, used
    /// to pick the live one when more than one file is present.
    private static func namesAccount(_ url: URL, fileManager: FileManager) -> Bool {
        guard let data = fileManager.contents(atPath: url.path) else { return false }
        return SessionSettings(raw: data).email != nil
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
