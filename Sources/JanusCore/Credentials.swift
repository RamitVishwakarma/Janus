import Foundation

/// The OAuth blob Claude Code keeps in the keychain, read well enough to use and
/// written back whole.
///
/// Only three fields matter here — the token to present, the token to renew with,
/// and the moment the first one stops working. Everything else in the blob
/// (`subscriptionType`, `scopes`, whatever a later release adds) is carried
/// through untouched, for the same reason the settings file is: it belongs to
/// another program.
public struct Credentials: Equatable, Sendable {

    /// The key Claude Code files all of this under.
    static let container = "claudeAiOauth"

    public let raw: Data
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init?(_ raw: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = root[Credentials.container] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty
        else { return nil }

        self.raw = raw
        self.accessToken = accessToken
        self.refreshToken = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let milliseconds = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        } else {
            expiresAt = nil
        }
    }

    /// Whether the access token can still be presented.
    ///
    /// A token about to expire counts as expired. The alternative is a request
    /// that sets off with two seconds of life left in it and comes back 401, and
    /// renewing first costs one round trip against a failure that costs two.
    public func isFresh(at now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > margin
    }

    /// The same blob with renewed tokens written into it.
    ///
    /// Rebuilt from the original JSON rather than from these three fields, so an
    /// entry that is written back is the entry that was read plus the parts that
    /// changed — which is what lets Claude Code go on using it afterwards.
    func renewed(accessToken: String,
                 refreshToken: String?,
                 expiresIn: TimeInterval?,
                 now: Date = Date()) -> Credentials? {
        guard var root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var oauth = root[Credentials.container] as? [String: Any]
        else { return nil }

        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresIn {
            oauth["expiresAt"] = now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000
        }
        root[Credentials.container] = oauth

        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        return Credentials(data)
    }
}
