import XCTest
@testable import JanusCore

/// Asking Anthropic for an account's figures, which is the only thing in Janus
/// that touches the network and the only way a parked account's numbers move.
final class FetchTests: XCTestCase {

    /// Two accounts saved, the second one signed in, so the first is a parked
    /// account whose settings file stopped moving when it was switched away from.
    private func twoAccounts(expiring: Date? = nil) throws -> Sandbox {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "parked@example.com",
                           credentials: Sandbox.oauthBlob(access: "parked-access",
                                                          refresh: "parked-refresh",
                                                          expiresAt: expiring),
                           usagePercent: 10)
        try sandbox.switcher.adoptCurrentAccount()

        try sandbox.signIn(email: "live@example.com",
                           credentials: Sandbox.oauthBlob(access: "live-access",
                                                          refresh: "live-refresh",
                                                          expiresAt: expiring),
                           usagePercent: 40)
        try sandbox.switcher.adoptCurrentAccount()
        return sandbox
    }

    // MARK: - The happy path

    func testFetchesAnAccountThatIsNotSignedIn() async throws {
        let sandbox = try twoAccounts()
        let parked = try sandbox.profile("parked@example.com")

        XCTAssertEqual(sandbox.switcher.usage(for: parked, isActive: false)?.fiveHour?.percentUsed,
                       10, "the figure on disk is the one frozen at its last sign-out")

        let fetched = try await sandbox.switcher.fetchUsage(for: parked, isActive: false)
        XCTAssertEqual(fetched.fiveHour?.percentUsed, 77)
        XCTAssertEqual(sandbox.api.tokensPresented, ["parked-access"])
    }

    func testAFetchedFigureIsKeptSoItSurvivesTheAppBeingQuit() async throws {
        let sandbox = try twoAccounts()
        let parked = try sandbox.profile("parked@example.com")

        _ = try await sandbox.switcher.fetchUsage(for: parked, isActive: false)

        // Read back the way the window reads it on the next launch: off the disk,
        // with nothing in memory to fall back on.
        let reread = sandbox.switcher.usage(for: parked, isActive: false)
        XCTAssertEqual(reread?.fiveHour?.percentUsed, 77)
    }

    func testKeepingAFetchedFigureLeavesTheRestOfTheFileAlone() async throws {
        let sandbox = try twoAccounts()
        let parked = try sandbox.profile("parked@example.com")

        _ = try await sandbox.switcher.fetchUsage(for: parked, isActive: false)

        let saved = try XCTUnwrap(sandbox.vault.storedSettings(for: parked.id))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(root["somethingJanusDoesNotKnowAbout"],
                        "the settings file belongs to another program and is written back whole")
        XCTAssertEqual((root["oauthAccount"] as? [String: Any])?["emailAddress"] as? String,
                       "parked@example.com")
    }

    func testTheLiveSettingsFileIsNeverWrittenTo() async throws {
        let sandbox = try twoAccounts()
        let live = try sandbox.profile("live@example.com")
        let before = try Data(contentsOf: sandbox.session.settingsURL)

        _ = try await sandbox.switcher.fetchUsage(for: live, isActive: true)

        XCTAssertEqual(try Data(contentsOf: sandbox.session.settingsURL), before,
                       "Claude Code is writing that file as it works; a second writer loses figures")
    }

    func testReadsTheDecimalPercentagesTheEndpointAnswersWith() async throws {
        let sandbox = try twoAccounts()
        sandbox.api.answer(withFiveHour: 73.4)

        let fetched = try await sandbox.switcher.fetchUsage(
            for: try sandbox.profile("parked@example.com"), isActive: false)

        XCTAssertEqual(fetched.fiveHour?.percentUsed, 73,
                       "the file holds these as integers and the endpoint as decimals")
    }

    // MARK: - An answer that is not a reading

    func testAnAnswerWithNoLimitsInItIsNotAReading() async throws {
        let sandbox = try twoAccounts()
        sandbox.api.answerWithNothing()

        do {
            _ = try await sandbox.switcher.fetchUsage(
                for: try sandbox.profile("parked@example.com"), isActive: false)
            XCTFail("an empty answer is not something to show")
        } catch let error as UsageAPIError {
            XCTAssertEqual(error, .noFigures)
        }
    }

    func testAnEmptyAnswerIsNeverWrittenOverTheFiguresItWouldReplace() async throws {
        let sandbox = try twoAccounts()
        let parked = try sandbox.profile("parked@example.com")
        sandbox.api.answerWithNothing()

        _ = try? await sandbox.switcher.fetchUsage(for: parked, isActive: false)

        // The one mistake here that asking again cannot undo.
        XCTAssertEqual(sandbox.switcher.usage(for: parked, isActive: false)?.fiveHour?.percentUsed,
                       10)
    }

    // MARK: - Renewing

    func testRenewsAnExpiredTokenBeforeAsking() async throws {
        let sandbox = try twoAccounts(expiring: Date().addingTimeInterval(-3600))
        let parked = try sandbox.profile("parked@example.com")

        _ = try await sandbox.switcher.fetchUsage(for: parked, isActive: false)

        XCTAssertEqual(sandbox.api.refreshTokensSpent, ["parked-refresh"])
        XCTAssertEqual(sandbox.api.tokensPresented, ["renewed-access-token"])
    }

    func testARenewedTokenIsStoredEvenWhenTheRequestItWasForFails() async throws {
        let sandbox = try twoAccounts(expiring: Date().addingTimeInterval(-3600))
        let parked = try sandbox.profile("parked@example.com")
        sandbox.api.failUsage(with: .refused(500))

        do {
            _ = try await sandbox.switcher.fetchUsage(for: parked, isActive: false)
            XCTFail("the fetch should have failed")
        } catch {}

        // The renewal already spent the old refresh token, so what came back is
        // the only way into this account that still exists. Losing it here is an
        // account that needs signing in again.
        let stored = try XCTUnwrap(sandbox.storedCredentials(for: parked.id))
        XCTAssertEqual(stored.accessToken, "renewed-access-token")
        XCTAssertEqual(stored.refreshToken, "parked-refresh-next")
    }

    func testARenewedBlobKeepsEverythingElseInIt() async throws {
        let sandbox = try twoAccounts(expiring: Date().addingTimeInterval(-3600))
        let parked = try sandbox.profile("parked@example.com")

        _ = try await sandbox.switcher.fetchUsage(for: parked, isActive: false)

        let raw = try XCTUnwrap(sandbox.storedCredentials(for: parked.id)?.raw)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["subscriptionType"] as? String, "pro",
                       "Claude Code reads this blob afterwards and needs all of it")
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference"])
    }

    func testTheSignedInAccountsTokenIsNeverRenewed() async throws {
        let sandbox = try twoAccounts(expiring: Date().addingTimeInterval(-3600))
        let live = try sandbox.profile("live@example.com")

        _ = try? await sandbox.switcher.fetchUsage(for: live, isActive: true)

        // Rotating it would leave a running Claude Code session holding a refresh
        // token that no longer works.
        XCTAssertTrue(sandbox.api.refreshTokensSpent.isEmpty)
        XCTAssertEqual(sandbox.api.tokensPresented, ["live-access"])
    }

    func testARefusalForTheSignedInAccountIsPhrasedForTheAccountItHappenedTo() async throws {
        let sandbox = try twoAccounts()
        sandbox.api.failUsage(with: .signInAgain)

        do {
            _ = try await sandbox.switcher.fetchUsage(
                for: try sandbox.profile("live@example.com"), isActive: true)
            XCTFail("the fetch should have failed")
        } catch let error as UsageAPIError {
            // "Switch to this account and sign in again" is advice that cannot be
            // followed by the account already signed in.
            XCTAssertEqual(error, .signInRefused)
        }
        XCTAssertTrue(sandbox.api.refreshTokensSpent.isEmpty)
    }

    func testATokenRenewedAndRefusedAnywayIsNotRenewedAgain() async throws {
        let sandbox = try twoAccounts(expiring: Date().addingTimeInterval(-3600))
        sandbox.api.failUsage(with: .signInAgain)

        do {
            _ = try await sandbox.switcher.fetchUsage(
                for: try sandbox.profile("parked@example.com"), isActive: false)
            XCTFail("the fetch should have failed")
        } catch let error as UsageAPIError {
            XCTAssertEqual(error, .signInAgain)
        }
        XCTAssertEqual(sandbox.api.refreshTokensSpent.count, 1,
                       "a renewed token refused too means the sign-in is gone, not stale")
    }

    func testARejectionInDateIsWorthOneRenewal() async throws {
        let sandbox = try twoAccounts()
        let parked = try sandbox.profile("parked@example.com")
        sandbox.api.failUsage(with: .signInAgain)

        do {
            _ = try await sandbox.switcher.fetchUsage(for: parked, isActive: false)
            XCTFail("the fetch should have failed")
        } catch {}

        XCTAssertEqual(sandbox.api.refreshTokensSpent, ["parked-refresh"])
        XCTAssertEqual(sandbox.api.tokensPresented, ["parked-access", "renewed-access-token"],
                       "tried once more with the renewed token rather than twice with the old one")
    }

    func testAnExpiredSignInWithNothingLeftToRenewWithSaysSo() async throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "parked@example.com",
                           credentials: Sandbox.oauthBlob(access: "parked-access",
                                                          refresh: nil,
                                                          expiresAt: Date(timeIntervalSince1970: 0)))
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "live@example.com", credentials: Sandbox.oauthBlob())
        try sandbox.switcher.adoptCurrentAccount()

        do {
            _ = try await sandbox.switcher.fetchUsage(
                for: try sandbox.profile("parked@example.com"), isActive: false)
            XCTFail("the fetch should have failed")
        } catch let error as UsageAPIError {
            XCTAssertEqual(error, .signInAgain)
        }
        XCTAssertTrue(sandbox.api.tokensPresented.isEmpty)
    }

    func testTokensInAShapeNothingUnderstandsAreNotSilentlyOverwritten() async throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "parked@example.com", token: "not-json-at-all")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "live@example.com", credentials: Sandbox.oauthBlob())
        try sandbox.switcher.adoptCurrentAccount()

        let parked = try sandbox.profile("parked@example.com")
        do {
            _ = try await sandbox.switcher.fetchUsage(for: parked, isActive: false)
            XCTFail("the fetch should have failed")
        } catch {}

        let raw = try sandbox.secrets.read(sandbox.vault.credentialAddress(for: parked.id))
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), "not-json-at-all",
                       "a session Janus cannot read is still a session that switching restores")
    }
}

/// The OAuth blob on its own: read well enough to use, written back whole.
final class CredentialsTests: XCTestCase {

    func testReadsTheThreeFieldsThatMatter() throws {
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = try XCTUnwrap(Credentials(Sandbox.oauthBlob(access: "a",
                                                                 refresh: "r",
                                                                 expiresAt: expiry)))
        XCTAssertEqual(parsed.accessToken, "a")
        XCTAssertEqual(parsed.refreshToken, "r")
        XCTAssertEqual(parsed.expiresAt?.timeIntervalSince1970 ?? 0,
                       expiry.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAnythingThatIsNotTheBlobIsRefused() {
        XCTAssertNil(Credentials(Data("token".utf8)))
        XCTAssertNil(Credentials(Data(#"{"claudeAiOauth":{}}"#.utf8)))
        XCTAssertNil(Credentials(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)))
    }

    func testAnEmptyRefreshTokenCountsAsNoneAtAll() throws {
        let parsed = try XCTUnwrap(
            Credentials(Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":""}}"#.utf8)))
        XCTAssertNil(parsed.refreshToken)
    }

    func testATokenWithNoExpiryIsTakenAtItsWord() throws {
        let parsed = try XCTUnwrap(Credentials(Sandbox.oauthBlob(expiresAt: nil)))
        XCTAssertTrue(parsed.isFresh(at: Date()))
    }

    func testATokenAboutToExpireCountsAsExpired() throws {
        let now = Date()
        let parsed = try XCTUnwrap(Credentials(
            Sandbox.oauthBlob(expiresAt: now.addingTimeInterval(30))))

        XCTAssertFalse(parsed.isFresh(at: now),
                       "a request that sets off with seconds left comes back 401")
        XCTAssertTrue(parsed.isFresh(at: now.addingTimeInterval(-600)))
    }

    func testRenewalRewritesTheBlobRatherThanRebuildingIt() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = try XCTUnwrap(Credentials(Sandbox.oauthBlob()))

        let renewed = try XCTUnwrap(parsed.renewed(accessToken: "fresh",
                                                   refreshToken: "fresher",
                                                   expiresIn: 3600,
                                                   now: now))
        XCTAssertEqual(renewed.accessToken, "fresh")
        XCTAssertEqual(renewed.refreshToken, "fresher")
        XCTAssertEqual(renewed.expiresAt?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 0.001)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: renewed.raw) as? [String: Any])
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["subscriptionType"] as? String, "pro")
    }

    func testARenewalThatReturnsNoNewRefreshTokenKeepsTheOldOne() throws {
        let parsed = try XCTUnwrap(Credentials(Sandbox.oauthBlob(refresh: "original")))
        let renewed = try XCTUnwrap(parsed.renewed(accessToken: "fresh",
                                                   refreshToken: nil,
                                                   expiresIn: nil))
        XCTAssertEqual(renewed.refreshToken, "original")
        XCTAssertNil(renewed.expiresAt)
    }
}
