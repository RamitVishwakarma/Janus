import Foundation

/// Where Codex keeps its sign-in.
///
/// One file, `auth.json`, in the Codex home directory. Unlike Claude Code there is
/// no keychain half: the tokens and everything else live in that file together,
/// so switching a Codex account is a matter of swapping one file.
public enum CodexHome {

    /// `$CODEX_HOME/auth.json` when that is set, `~/.codex/auth.json` otherwise.
    ///
    /// An app launched from Finder does not inherit a shell's environment, so in
    /// practice the variable is only seen when Janus is started from a terminal.
    /// It is honoured anyway, because a Janus that looked somewhere Codex does not
    /// would save and restore a file nobody reads.
    public static func authFile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex/auth.json")
    }
}

/// Codex's `auth.json`, read well enough to say whose it is and to present its
/// token, and written back whole.
///
/// It holds one of two kinds of sign-in: a ChatGPT sign-in, which is a set of
/// OAuth tokens whose ID token names the account, or an OpenAI API key. Anything
/// else in the file is carried through untouched, for the same reason Claude
/// Code's files are: it belongs to another program, and gains keys between
/// releases.
public struct CodexAuth: Equatable, Sendable {

    public let raw: Data
    public let apiKey: String?
    public let idToken: String?
    public let accessToken: String?
    public let refreshToken: String?

    /// The ChatGPT workspace the tokens belong to. The same email can be signed
    /// into a personal plan and a team plan, and this is what tells them apart.
    public let accountID: String?
    public let email: String?
    public let plan: String?

    public init?(_ raw: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return nil }

        self.raw = raw
        apiKey = Self.text(root["OPENAI_API_KEY"])

        let tokens = root["tokens"] as? [String: Any]
        idToken = Self.text(tokens?["id_token"])
        accessToken = Self.text(tokens?["access_token"])
        refreshToken = Self.text(tokens?["refresh_token"])

        let claims = idToken.flatMap(JWT.claims) ?? [:]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]

        accountID = Self.text(tokens?["account_id"]) ?? Self.text(auth?["chatgpt_account_id"])
        email = Self.text(claims["email"]) ?? Self.text(profile?["email"])
        plan = Self.text(auth?["chatgpt_plan_type"])
    }

    /// True for a ChatGPT sign-in, which is the only kind that has usage limits
    /// to ask about.
    public var usesChatGPT: Bool { accessToken != nil }

    /// What the account is called on screen, and what it is recognised by.
    ///
    /// A ChatGPT sign-in is its email. An API key has no owner written anywhere
    /// in the file, so it is named by its last four characters, the way the
    /// OpenAI dashboard names keys. Older versions of Codex wrote a key alongside
    /// the tokens, so the tokens are looked at first.
    public var name: String? {
        if usesChatGPT {
            if let email { return email }
            if let accountID { return "ChatGPT account \(accountID.suffix(8))" }
            return "ChatGPT account"
        }
        if let apiKey { return "API key …\(apiKey.suffix(4))" }
        return nil
    }

    /// A file that parses but holds neither kind of sign-in is what Codex leaves
    /// behind after logging out, and is not worth saving.
    public var isSignedIn: Bool { name != nil }

    /// When the access token stops working, from its own `exp` claim.
    public var expiresAt: Date? {
        accessToken.flatMap(JWT.expiry)
    }

    /// Whether the access token can still be presented. A token about to run out
    /// counts as run out, for the reason given on `Credentials.isFresh`.
    public func isFresh(at now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > margin
    }

    /// The same file with renewed tokens written into it.
    ///
    /// `last_refresh` moves too, because it is what Codex reads to decide whether
    /// its own tokens need renewing. Leaving the old date in place would have it
    /// spend the new refresh token the moment it next starts, for nothing.
    func renewed(idToken: String?,
                 accessToken: String,
                 refreshToken: String?,
                 now: Date = Date()) -> CodexAuth? {
        guard var root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any]
        else { return nil }

        tokens["access_token"] = accessToken
        if let idToken { tokens["id_token"] = idToken }
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        root["tokens"] = tokens

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = stamp.string(from: now)

        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return CodexAuth(data)
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

extension Roster {

    /// The saved account a Codex sign-in belongs to.
    ///
    /// Matched on the name first and the workspace second. A profile saved
    /// without a workspace, or a sign-in that names none, matches on name alone,
    /// but two that both name one have to agree, or a personal plan and a team
    /// plan under the same email would overwrite each other's saved sign-in.
    public func profile(for auth: CodexAuth) -> Profile? {
        guard let name = auth.name else { return nil }
        return profiles.first { profile in
            guard profile.email.caseInsensitiveCompare(name) == .orderedSame else { return false }
            guard let saved = profile.accountID, let live = auth.accountID else { return true }
            return saved == live
        }
    }
}

/// Just enough of a JSON Web Token to read what it says about itself.
///
/// The signature is not checked, and does not need to be: nothing here trusts a
/// claim for anything but a label on screen and a guess at when to renew, and
/// the server checks the token properly whenever it is presented.
enum JWT {

    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !base64.count.isMultiple(of: 4) { base64 += "=" }

        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        guard let seconds = claims(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }
}
