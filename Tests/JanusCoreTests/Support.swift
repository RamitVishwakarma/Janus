import Foundation
import XCTest
@testable import JanusCore

/// A throwaway home directory plus an in-memory keychain, so a test can exercise
/// the real code without touching the machine running it.
final class Sandbox {

    let home: URL
    let secrets = MemorySecretStore()
    let vault: Vault
    let session: Session
    let switcher: Switcher
    let api = StubUsageEndpoint()

    init(file: StaticString = #filePath, line: UInt = #line) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        vault = Vault(root: home.appendingPathComponent("vault"), secrets: secrets)
        session = Session(credentials: SecretAddress(service: "Claude Code-credentials",
                                                     account: "tester"),
                          settingsURL: home.appendingPathComponent(".claude.json"))
        switcher = Switcher(vault: vault, session: session, secrets: secrets, api: api)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// Puts an account into the live slot, as if it had just been signed in.
    func signIn(email: String, token: String = "token", usagePercent: Int? = nil) throws {
        try secrets.write(Data(token.utf8), to: session.credentials)
        try settings(email: email, usagePercent: usagePercent).write(to: session.settingsURL)
    }

    /// The same, but with tokens in the shape Claude Code actually writes, which
    /// is what anything reaching for the network needs.
    func signIn(email: String,
                credentials: Data,
                usagePercent: Int? = nil) throws {
        try secrets.write(credentials, to: session.credentials)
        try settings(email: email, usagePercent: usagePercent).write(to: session.settingsURL)
    }

    /// An OAuth blob, carrying one key nothing in Janus knows about so that tests
    /// can tell a blob that was rewritten from one that was rebuilt.
    static func oauthBlob(access: String = "access-token",
                          refresh: String? = "refresh-token",
                          expiresAt: Date? = nil) -> Data {
        var oauth: [String: Any] = ["accessToken": access,
                                    "subscriptionType": "pro",
                                    "scopes": ["user:inference"]]
        if let refresh { oauth["refreshToken"] = refresh }
        if let expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000 }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    func storedCredentials(for id: UUID) -> Credentials? {
        try? vault.credentials(for: id)
    }

    func profile(_ email: String) throws -> Profile {
        let roster = try switcher.roster()
        return roster.profile(withEmail: email)!
    }

    func signOut() throws {
        try? FileManager.default.removeItem(at: session.settingsURL)
        try secrets.remove(session.credentials)
    }

    /// Makes the live keychain entry unreadable, the way macOS leaves it when
    /// its permission prompt is declined or never answered.
    func refuseLiveKeychain() {
        secrets.refuseReads(of: session.credentials)
    }

    func allowLiveKeychain() {
        secrets.allowReads(of: session.credentials)
    }

    var liveToken: String? {
        (try? secrets.read(session.credentials)).map { String(decoding: $0, as: UTF8.self) }
    }

    var liveEmail: String? {
        switcher.liveSettings()?.email
    }

    func settings(email: String, usagePercent: Int? = nil) -> Data {
        var root: [String: Any] = [
            "oauthAccount": ["emailAddress": email, "accountUuid": UUID().uuidString],
            "somethingJanusDoesNotKnowAbout": ["keep": true]
        ]
        if let usagePercent {
            root["cachedUsageUtilization"] = [
                "fetchedAtMs": Date().timeIntervalSince1970 * 1000,
                "utilization": [
                    "five_hour": ["utilization": usagePercent,
                                  "resets_at": "2030-01-01T00:00:00Z"],
                    "seven_day": ["utilization": usagePercent / 2,
                                  "resets_at": "2030-01-02T00:00:00Z"],
                    "seven_day_breakdown": ["rows": [["display_name": "Claude Code",
                                                      "percent": 97]]]
                ]
            ]
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }
}


/// Stands in for Anthropic. Answers with whatever a test set, and remembers what
/// it was asked, which is how the order of the steps gets asserted: a renewal has
/// to be stored before the request it was for is made.
final class StubUsageEndpoint: UsageEndpoint, @unchecked Sendable {

    private let lock = NSLock()

    private var _limits: [String: Any] = [
        "five_hour": ["utilization": 77, "resets_at": "2030-01-01T00:00:00Z"],
        "seven_day": ["utilization": 12, "resets_at": "2030-01-02T00:00:00Z"]
    ]
    private var _usageFailure: UsageAPIError?
    private var _renewFailure: UsageAPIError?
    private var _tokensPresented: [String] = []
    private var _refreshTokensSpent: [String] = []

    /// The access token the next renewal hands back.
    var issues = "renewed-access-token"

    func answer(withFiveHour percent: Any) {
        lock.lock(); defer { lock.unlock() }
        _limits["five_hour"] = ["utilization": percent, "resets_at": "2030-01-01T00:00:00Z"]
    }

    /// The empty object Claude Code's own client answers with for an account it
    /// cannot measure.
    func answerWithNothing() {
        lock.lock(); defer { lock.unlock() }
        _limits = [:]
    }

    func failUsage(with error: UsageAPIError?) {
        lock.lock(); defer { lock.unlock() }
        _usageFailure = error
    }

    func failRenewal(with error: UsageAPIError?) {
        lock.lock(); defer { lock.unlock() }
        _renewFailure = error
    }

    var tokensPresented: [String] {
        lock.lock(); defer { lock.unlock() }
        return _tokensPresented
    }

    var refreshTokensSpent: [String] {
        lock.lock(); defer { lock.unlock() }
        return _refreshTokensSpent
    }

    func usage(accessToken: String) async throws -> Data {
        lock.lock()
        _tokensPresented.append(accessToken)
        let failure = _usageFailure
        let limits = _limits
        lock.unlock()

        if let failure { throw failure }
        return try JSONSerialization.data(withJSONObject: limits)
    }

    func renew(_ credentials: Credentials, now: Date) async throws -> Credentials {
        lock.lock()
        let failure = _renewFailure
        let issued = issues
        if let refresh = credentials.refreshToken { _refreshTokensSpent.append(refresh) }
        lock.unlock()

        if let failure { throw failure }
        guard let refreshToken = credentials.refreshToken else { throw UsageAPIError.signInAgain }
        return credentials.renewed(accessToken: issued,
                                   refreshToken: refreshToken + "-next",
                                   expiresIn: 3600,
                                   now: now)!
    }
}
