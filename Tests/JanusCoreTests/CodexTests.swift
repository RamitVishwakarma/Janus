import Foundation
import XCTest
@testable import JanusCore

/// A throwaway Codex home and an in-memory keychain, the Codex counterpart of
/// `Sandbox`.
final class CodexSandbox {

    let home: URL
    let secrets = MemorySecretStore()
    let vault: CodexVault
    let authURL: URL
    let api = StubCodexEndpoint()
    let switcher: CodexSwitcher

    /// What the switcher is told when it asks whether Codex is running.
    let running = Flag()

    init() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-codex-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        vault = CodexVault(root: home.appendingPathComponent("vault"), secrets: secrets)
        authURL = home.appendingPathComponent(".codex/auth.json")
        let flag = running
        switcher = CodexSwitcher(vault: vault, authURL: authURL, api: api,
                                 isCodexRunning: { flag.value })
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// Writes an `auth.json` the way `codex login` leaves it.
    func signIn(email: String,
                workspace: String = "example-workspace",
                plan: String = "plus",
                access: String? = nil,
                refresh: String = "example-refresh-token",
                extra: [String: Any] = [:]) throws {
        let data = Self.auth(email: email, workspace: workspace, plan: plan,
                             access: access, refresh: refresh, extra: extra)
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: authURL)
    }

    func signOut() throws {
        try? FileManager.default.removeItem(at: authURL)
    }

    var live: CodexAuth? { switcher.liveAuth() }

    func profile(_ email: String, plan: String? = nil) throws -> Profile {
        try XCTUnwrap(switcher.roster().profiles.first {
            $0.email == email && (plan == nil || $0.plan == plan)
        })
    }

    static func auth(email: String,
                     workspace: String = "example-workspace",
                     plan: String = "plus",
                     access: String? = nil,
                     refresh: String = "example-refresh-token",
                     extra: [String: Any] = [:]) -> Data {
        let idToken = jwt([
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": workspace,
                                            "chatgpt_plan_type": plan]
        ])
        var root: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "tokens": ["id_token": idToken,
                       "access_token": access ?? jwt(["exp": Date().addingTimeInterval(86_400)
                                                                .timeIntervalSince1970]),
                       "refresh_token": refresh,
                       "account_id": workspace],
            "last_refresh": "2026-01-01T00:00:00Z"
        ]
        for (key, value) in extra { root[key] = value }
        return try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    }

    /// A token with the given claims and a signature nothing checks.
    static func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "example-header.\(payload).example-signature"
    }

    final class Flag: @unchecked Sendable {
        var value = false
    }
}

/// Stands in for OpenAI, and remembers what it was asked.
final class StubCodexEndpoint: CodexUsageEndpoint, @unchecked Sendable {

    private let lock = NSLock()
    private var _body: [String: Any] = [
        "plan_type": "plus",
        "rate_limit": [
            "primary_window": ["used_percent": 42.4, "limit_window_seconds": 18_000,
                               "reset_at": 1_900_000_000],
            "secondary_window": ["used_percent": 7, "limit_window_seconds": 604_800,
                                 "reset_at": 1_900_500_000]
        ]
    ]
    private var _usageFailure: CodexAPIError?
    private var _tokensPresented: [String] = []
    private var _refreshTokensSpent: [String] = []

    func failUsage(with error: CodexAPIError?) {
        lock.lock(); defer { lock.unlock() }
        _usageFailure = error
    }

    var tokensPresented: [String] {
        lock.lock(); defer { lock.unlock() }
        return _tokensPresented
    }

    var refreshTokensSpent: [String] {
        lock.lock(); defer { lock.unlock() }
        return _refreshTokensSpent
    }

    func usage(accessToken: String, accountID: String?) async throws -> Data {
        lock.lock()
        _tokensPresented.append(accessToken)
        let failure = _usageFailure
        let body = _body
        lock.unlock()

        if let failure { throw failure }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func renew(_ auth: CodexAuth, now: Date) async throws -> CodexAuth {
        lock.lock()
        if let refresh = auth.refreshToken { _refreshTokensSpent.append(refresh) }
        lock.unlock()

        guard let refresh = auth.refreshToken else { throw CodexAPIError.signInAgain }
        return auth.renewed(idToken: nil,
                            accessToken: "example-renewed-access",
                            refreshToken: refresh + "-next",
                            now: now)!
    }
}

// MARK: - Reading auth.json

final class CodexAuthTests: XCTestCase {

    func testReadsWhoTheSignInBelongsTo() throws {
        let auth = try XCTUnwrap(CodexAuth(CodexSandbox.auth(email: "sam@example.com",
                                                             workspace: "example-ws",
                                                             plan: "pro")))
        XCTAssertEqual(auth.name, "sam@example.com")
        XCTAssertEqual(auth.accountID, "example-ws")
        XCTAssertEqual(auth.plan, "pro")
        XCTAssertTrue(auth.usesChatGPT)
    }

    func testAnAPIKeyIsNamedByItsLastFourCharacters() throws {
        let data = try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "example-key-abcd"])
        let auth = try XCTUnwrap(CodexAuth(data))
        XCTAssertEqual(auth.name, "API key …abcd")
        XCTAssertFalse(auth.usesChatGPT)
    }

    func testALoggedOutFileIsNotASignIn() throws {
        let data = try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": NSNull()])
        XCTAssertFalse(try XCTUnwrap(CodexAuth(data)).isSignedIn)
    }

    func testFreshnessComesFromTheAccessTokensOwnExpiry() throws {
        let soon = CodexSandbox.jwt(["exp": Date().addingTimeInterval(30).timeIntervalSince1970])
        let auth = try XCTUnwrap(CodexAuth(CodexSandbox.auth(email: "a@example.com", access: soon)))
        XCTAssertFalse(auth.isFresh())
    }

    func testRenewingKeepsKeysItDoesNotKnowAbout() throws {
        let original = try XCTUnwrap(CodexAuth(CodexSandbox.auth(
            email: "a@example.com", extra: ["auth_mode": "chatgpt"])))
        let renewed = try XCTUnwrap(original.renewed(idToken: nil, accessToken: "example-new",
                                                     refreshToken: "example-new-refresh"))

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: renewed.raw) as? [String: Any])
        XCTAssertEqual(root["auth_mode"] as? String, "chatgpt")
        XCTAssertNotEqual(root["last_refresh"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(renewed.accessToken, "example-new")
        XCTAssertEqual(renewed.refreshToken, "example-new-refresh")
        XCTAssertEqual(renewed.email, "a@example.com")
    }

    func testCodexHomeIsHonoured() {
        let home = URL(fileURLWithPath: "/Users/tester")
        XCTAssertEqual(CodexHome.authFile(environment: [:], home: home).path,
                       "/Users/tester/.codex/auth.json")
        XCTAssertEqual(CodexHome.authFile(environment: ["CODEX_HOME": "/tmp/elsewhere"], home: home).path,
                       "/tmp/elsewhere/auth.json")
    }

    func testFormEncodingEscapesWhatAFormWouldMangle() {
        XCTAssertEqual(OpenAIUsage.form([("refresh_token", "a+b/c=d e")]),
                       "refresh_token=a%2Bb%2Fc%3Dd%20e")
    }
}

// MARK: - Usage

final class CodexUsageTests: XCTestCase {

    func testReadsBothWindows() {
        let usage = Usage(codex: [
            "rate_limit": [
                "primary_window": ["used_percent": 42.6, "limit_window_seconds": 18_000,
                                   "reset_at": 1_900_000_000],
                "secondary_window": ["used_percent": 7, "limit_window_seconds": 604_800,
                                     "reset_at": 1_900_500_000]
            ]
        ], measuredAt: Date())

        XCTAssertEqual(usage.fiveHour?.percentUsed, 43)
        XCTAssertEqual(usage.sevenDay?.percentUsed, 7)
        XCTAssertEqual(usage.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testAWeeklyWindowSentAsPrimaryIsDrawnAsWeekly() {
        let usage = Usage(codex: [
            "rate_limit": [
                "primary_window": ["used_percent": 55, "limit_window_seconds": 604_800]
            ]
        ], measuredAt: Date())

        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay?.percentUsed, 55)
    }

    func testAResetGivenAsADelayIsCountedFromTheMeasurement() {
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(codex: [
            "rate_limit": ["primary_window": ["used_percent": 1, "reset_after_seconds": 600]]
        ], measuredAt: moment)

        XCTAssertEqual(usage.fiveHour?.resetsAt, moment.addingTimeInterval(600))
    }

    func testNoLimitsIsEmpty() {
        XCTAssertTrue(Usage(codex: ["plan_type": "plus"], measuredAt: Date()).isEmpty)
    }
}

// MARK: - Switching

final class CodexSwitcherTests: XCTestCase {

    func testSavingTheCurrentAccountRecordsItsWorkspaceAndPlan() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1", plan: "pro")

        try sandbox.switcher.adoptCurrentAccount()

        let profile = try sandbox.profile("first@example.com")
        XCTAssertEqual(profile.accountID, "example-ws-1")
        XCTAssertEqual(profile.plan, "pro")
        XCTAssertTrue(sandbox.vault.hasSession(for: profile.id))
        XCTAssertEqual(try sandbox.switcher.roster().activeID, profile.id)
    }

    func testSavingWithNobodySignedInIsRefused() throws {
        let sandbox = try CodexSandbox()
        XCTAssertThrowsError(try sandbox.switcher.adoptCurrentAccount()) { error in
            XCTAssertEqual(error as? CodexSwitchError, .notSignedIn)
        }
    }

    func testOneEmailInTwoWorkspacesIsTwoAccounts() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "sam@example.com", workspace: "example-personal", plan: "plus")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "sam@example.com", workspace: "example-team", plan: "team")
        try sandbox.switcher.adoptCurrentAccount()

        XCTAssertEqual(try sandbox.switcher.roster().profiles.map(\.plan), ["plus", "team"])
    }

    func testSwitchingSwapsTheLiveFileAndKeepsItWhole() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1")
        let original = try Data(contentsOf: sandbox.authURL)
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", workspace: "example-ws-2")
        try sandbox.switcher.adoptCurrentAccount()

        let outcome = try sandbox.switcher.activate(sandbox.profile("first@example.com").id)

        XCTAssertEqual(sandbox.live?.email, "first@example.com")
        XCTAssertEqual(try Data(contentsOf: sandbox.authURL), original)
        XCTAssertTrue(outcome.headline.contains("first@example.com"))
    }

    func testTheLiveFileIsOwnerOnly() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", workspace: "example-ws-2")
        try sandbox.switcher.adoptCurrentAccount()

        try sandbox.switcher.activate(sandbox.profile("first@example.com").id)

        let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.authURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// The case that makes Codex different: it rotates its own refresh token, and
    /// the copy saved when the account was added stops working when it does.
    func testSwitchingAwaySavesTheTokenCodexRotatedSinceItWasAdded() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", workspace: "example-ws-2")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.switcher.activate(sandbox.profile("first@example.com").id)

        // Codex renews while first@ is live.
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1",
                           refresh: "example-rotated-refresh")

        try sandbox.switcher.activate(sandbox.profile("second@example.com").id)
        try sandbox.switcher.activate(sandbox.profile("first@example.com").id)

        XCTAssertEqual(sandbox.live?.refreshToken, "example-rotated-refresh")
    }

    func testSwitchingToTheSignedInAccountIsRefused() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com")
        try sandbox.switcher.adoptCurrentAccount()

        XCTAssertThrowsError(try sandbox.switcher.activate(sandbox.profile("first@example.com").id)) {
            XCTAssertEqual($0 as? CodexSwitchError, .alreadyActive("first@example.com"))
        }
    }

    func testSwitchingAwayFromAnUnsavedAccountKeepsIt() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "saved@example.com", workspace: "example-ws-1")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "stranger@example.com", workspace: "example-ws-2")

        let outcome = try sandbox.switcher.activate(sandbox.profile("saved@example.com").id)

        XCTAssertEqual(try sandbox.switcher.roster().profiles.map(\.email),
                       ["saved@example.com", "stranger@example.com"])
        XCTAssertTrue(sandbox.vault.hasSession(for: try sandbox.profile("stranger@example.com").id))
        XCTAssertTrue(outcome.notes.contains { $0.contains("stranger@example.com") })
    }

    func testAMissingSavedSignInLeavesTheLiveOneAlone() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", workspace: "example-ws-2")
        try sandbox.switcher.adoptCurrentAccount()

        let first = try sandbox.profile("first@example.com")
        sandbox.vault.discard(for: first.id)

        XCTAssertThrowsError(try sandbox.switcher.activate(first.id))
        XCTAssertEqual(sandbox.live?.email, "second@example.com")
    }

    func testSwitchingWithNobodySignedInWritesTheFile() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signOut()
        try FileManager.default.removeItem(at: sandbox.authURL.deletingLastPathComponent())

        try sandbox.switcher.activate(sandbox.profile("first@example.com").id)

        XCTAssertEqual(sandbox.live?.email, "first@example.com")
    }

    func testARunningCodexIsCalledOut() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", workspace: "example-ws-2")
        try sandbox.switcher.adoptCurrentAccount()
        sandbox.running.value = true

        let outcome = try sandbox.switcher.activate(sandbox.profile("first@example.com").id)

        XCTAssertTrue(outcome.notes.contains { $0.contains("Codex is running") })
    }

    func testNextWrapsAroundFromTheLiveAccount() throws {
        let sandbox = try CodexSandbox()
        for (index, email) in ["a@example.com", "b@example.com"].enumerated() {
            try sandbox.signIn(email: email, workspace: "example-ws-\(index)")
            try sandbox.switcher.adoptCurrentAccount()
        }

        try sandbox.switcher.switchToNext()
        XCTAssertEqual(sandbox.live?.email, "a@example.com")
        try sandbox.switcher.switchToNext()
        XCTAssertEqual(sandbox.live?.email, "b@example.com")
    }

    func testRemovingDropsTheSavedSignIn() throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com")
        try sandbox.switcher.adoptCurrentAccount()
        let profile = try sandbox.profile("first@example.com")

        try sandbox.switcher.remove(profile.id)

        XCTAssertTrue(try sandbox.switcher.roster().profiles.isEmpty)
        XCTAssertFalse(sandbox.vault.hasSession(for: profile.id))
        XCTAssertEqual(sandbox.live?.email, "first@example.com")
    }

    func testARosterWrittenBeforeWorkspacesStillReads() throws {
        let sandbox = try CodexSandbox()
        let legacy = """
            {"schema": 1, "profiles": [{"id": "\(UUID().uuidString)", \
            "email": "old@example.com", "addedAt": "2026-01-01T00:00:00Z"}]}
            """
        try FileManager.default.createDirectory(at: sandbox.vault.root, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: sandbox.vault.root.appendingPathComponent("roster.json"))

        let profile = try XCTUnwrap(sandbox.switcher.roster().profiles.first)
        XCTAssertEqual(profile.email, "old@example.com")
        XCTAssertNil(profile.accountID)
    }
}

// MARK: - Fetching

final class CodexFetchTests: XCTestCase {

    func testTheSignedInAccountIsNeverRenewed() async throws {
        let sandbox = try CodexSandbox()
        let expired = CodexSandbox.jwt(["exp": Date().addingTimeInterval(-60).timeIntervalSince1970])
        try sandbox.signIn(email: "first@example.com", access: expired)
        try sandbox.switcher.adoptCurrentAccount()
        sandbox.api.failUsage(with: .signInAgain)

        do {
            _ = try await sandbox.switcher.fetchUsage(for: sandbox.profile("first@example.com"),
                                                      isActive: true)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? CodexAPIError, .signInRefused)
        }
        XCTAssertEqual(sandbox.api.refreshTokensSpent, [])
    }

    func testAnExpiredSavedAccountIsRenewedAndStoredBeforeAsking() async throws {
        let sandbox = try CodexSandbox()
        let expired = CodexSandbox.jwt(["exp": Date().addingTimeInterval(-60).timeIntervalSince1970])
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1", access: expired)
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", workspace: "example-ws-2")
        try sandbox.switcher.adoptCurrentAccount()

        let first = try sandbox.profile("first@example.com")
        let usage = try await sandbox.switcher.fetchUsage(for: first, isActive: false)

        XCTAssertEqual(usage.fiveHour?.percentUsed, 42)
        XCTAssertEqual(usage.sevenDay?.percentUsed, 7)
        XCTAssertEqual(sandbox.api.refreshTokensSpent, ["example-refresh-token"])
        XCTAssertEqual(sandbox.api.tokensPresented, ["example-renewed-access"])
        XCTAssertEqual(try sandbox.vault.auth(for: first.id).refreshToken,
                       "example-refresh-token-next")
    }

    func testAForbiddenAnswerDoesNotSpendARefreshToken() async throws {
        let sandbox = try CodexSandbox()
        try sandbox.signIn(email: "first@example.com", workspace: "example-ws-1")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", workspace: "example-ws-2")
        try sandbox.switcher.adoptCurrentAccount()
        sandbox.api.failUsage(with: .refused(403))

        do {
            _ = try await sandbox.switcher.fetchUsage(for: sandbox.profile("first@example.com"),
                                                      isActive: false)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? CodexAPIError, .refused(403))
        }
        XCTAssertEqual(sandbox.api.refreshTokensSpent, [])
    }

    func testAnAPIKeyAccountIsNotAsked() async throws {
        let sandbox = try CodexSandbox()
        try FileManager.default.createDirectory(at: sandbox.authURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "example-key-abcd"])
            .write(to: sandbox.authURL)
        try sandbox.switcher.adoptCurrentAccount()

        do {
            _ = try await sandbox.switcher.fetchUsage(for: sandbox.profile("API key …abcd"),
                                                      isActive: true)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error as? CodexAPIError, .apiKeyAccount)
        }
        XCTAssertEqual(sandbox.api.tokensPresented, [])
    }
}
