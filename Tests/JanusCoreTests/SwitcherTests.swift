import XCTest
@testable import JanusCore

final class SwitcherTests: XCTestCase {

    func testAddingTheCurrentAccountSavesBothHalves() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "first@example.com", token: "first-token")

        let outcome = try sandbox.switcher.adoptCurrentAccount()
        let roster = try sandbox.switcher.roster()

        XCTAssertEqual(roster.profiles.map(\.email), ["first@example.com"])
        XCTAssertEqual(roster.active?.email, "first@example.com")
        XCTAssertTrue(sandbox.vault.hasSession(for: roster.profiles[0].id))
        XCTAssertTrue(outcome.headline.contains("first@example.com"))
    }

    func testAddingTwiceUpdatesRatherThanDuplicating() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "first@example.com", token: "old")
        try sandbox.switcher.adoptCurrentAccount()

        try sandbox.signIn(email: "first@example.com", token: "new")
        try sandbox.switcher.adoptCurrentAccount()

        let roster = try sandbox.switcher.roster()
        XCTAssertEqual(roster.profiles.count, 1)

        let stored = try sandbox.vault.session(for: roster.profiles[0].id)
        XCTAssertEqual(String(decoding: stored.credentials, as: UTF8.self), "new")
    }

    func testAddingWithNobodySignedInIsRefused() throws {
        let sandbox = try Sandbox()
        XCTAssertThrowsError(try sandbox.switcher.adoptCurrentAccount()) { error in
            XCTAssertEqual(error as? SwitchError, .notSignedIn)
        }
    }

    func testSwitchingSwapsTheLiveSession() throws {
        let sandbox = try Sandbox()

        try sandbox.signIn(email: "first@example.com", token: "first-token")
        try sandbox.switcher.adoptCurrentAccount()

        try sandbox.signIn(email: "second@example.com", token: "second-token")
        try sandbox.switcher.adoptCurrentAccount()

        let first = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "first@example.com"))
        let outcome = try sandbox.switcher.activate(first.id)

        XCTAssertEqual(sandbox.liveEmail, "first@example.com")
        XCTAssertEqual(sandbox.liveToken, "first-token")
        XCTAssertEqual(try sandbox.switcher.roster().active?.email, "first@example.com")
        XCTAssertTrue(outcome.headline.contains("first@example.com"))
    }

    func testSwitchingSavesTheAccountItLeaves() throws {
        let sandbox = try Sandbox()

        try sandbox.signIn(email: "first@example.com", token: "first-token")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", token: "second-token")
        try sandbox.switcher.adoptCurrentAccount()

        let first = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "first@example.com"))
        try sandbox.switcher.activate(first.id)

        // Going back has to produce the session that was displaced, tokens included.
        let second = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "second@example.com"))
        try sandbox.switcher.activate(second.id)

        XCTAssertEqual(sandbox.liveEmail, "second@example.com")
        XCTAssertEqual(sandbox.liveToken, "second-token")
    }

    func testSwitchingAwayFromAnUnmanagedAccountKeepsIt() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "saved@example.com", token: "saved-token")
        try sandbox.switcher.adoptCurrentAccount()

        // Somebody signs in by hand, outside the app.
        try sandbox.signIn(email: "stranger@example.com", token: "stranger-token")

        let saved = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "saved@example.com"))
        let outcome = try sandbox.switcher.activate(saved.id)

        let roster = try sandbox.switcher.roster()
        let stranger = try XCTUnwrap(roster.profile(withEmail: "stranger@example.com"))
        XCTAssertTrue(sandbox.vault.hasSession(for: stranger.id),
                      "credentials that exist nowhere else must not be overwritten")
        XCTAssertTrue(outcome.notes.contains { $0.contains("stranger@example.com") })
    }

    func testARefusedKeychainStopsTheSwitchRatherThanLoseTheSession() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "first@example.com", token: "first-token")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", token: "second-token")
        try sandbox.switcher.adoptCurrentAccount()

        let first = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "first@example.com"))
        let second = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "second@example.com"))
        try sandbox.switcher.activate(first.id)

        // Claude Code rotates the live tokens while the account is in use, so the
        // keychain now holds the only copy that still works.
        try sandbox.secrets.write(Data("rotated-token".utf8), to: sandbox.session.credentials)
        sandbox.refuseLiveKeychain()

        XCTAssertThrowsError(try sandbox.switcher.activate(second.id),
                             "a keychain that will not give up the live tokens must stop the switch")

        // Carrying on would have written second@ over the only copy of the
        // rotated tokens, leaving first@ needing a fresh sign-in.
        sandbox.allowLiveKeychain()
        XCTAssertEqual(sandbox.liveEmail, "first@example.com")
        XCTAssertEqual(sandbox.liveToken, "rotated-token")
    }

    func testSwitchingAwayFromAnAccountWhoseTokensAreAlreadyGoneIsAllowed() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "saved@example.com", token: "saved-token")
        try sandbox.switcher.adoptCurrentAccount()

        // Settings still name an account, but its tokens have been signed out
        // from under them. There is no session here left to lose.
        try sandbox.settings(email: "stale@example.com").write(to: sandbox.session.settingsURL)
        try sandbox.secrets.remove(sandbox.session.credentials)

        let saved = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "saved@example.com"))
        XCTAssertNoThrow(try sandbox.switcher.activate(saved.id))
        XCTAssertEqual(sandbox.liveEmail, "saved@example.com")
    }

    func testCapturingLiveUsageBringsTheSavedCopyUpToDate() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "busy@example.com", usagePercent: 10)
        try sandbox.switcher.adoptCurrentAccount()

        let profile = try XCTUnwrap(sandbox.switcher.roster().profiles.first)
        XCTAssertEqual(sandbox.switcher.usage(for: profile, isActive: false)?.fiveHour?.percentUsed, 10)

        // Claude Code measures more while the account stays signed in.
        try sandbox.settings(email: "busy@example.com", usagePercent: 90)
            .write(to: sandbox.session.settingsURL)

        XCTAssertEqual(sandbox.switcher.captureLiveUsage(), profile.id)
        XCTAssertEqual(sandbox.switcher.usage(for: profile, isActive: false)?.fiveHour?.percentUsed, 90)
        XCTAssertEqual(sandbox.liveToken, "token", "refreshing figures must not touch the tokens")
    }

    func testCapturingLiveUsageIgnoresAnAccountWithNoSavedSlot() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "unmanaged@example.com", usagePercent: 50)
        XCTAssertNil(sandbox.switcher.captureLiveUsage())
        XCTAssertTrue(try sandbox.switcher.roster().profiles.isEmpty)
    }

    func testSwitchingToTheActiveAccountIsRefused() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "only@example.com")
        try sandbox.switcher.adoptCurrentAccount()

        let only = try XCTUnwrap(sandbox.switcher.roster().profiles.first)
        XCTAssertThrowsError(try sandbox.switcher.activate(only.id)) { error in
            XCTAssertEqual(error as? SwitchError, .alreadyActive("only@example.com"))
        }
    }

    func testSwitchingBackToAStaleActiveRecordIsAllowed() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "first@example.com", token: "first-token")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", token: "second-token")
        try sandbox.switcher.adoptCurrentAccount()

        // Signing in by hand leaves the roster still naming the previous account
        // as active. Asking to switch to it is then a real request, not a no-op.
        try sandbox.signIn(email: "first@example.com", token: "first-token")
        let second = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "second@example.com"))

        XCTAssertNoThrow(try sandbox.switcher.activate(second.id))
        XCTAssertEqual(sandbox.liveEmail, "second@example.com")
    }

    func testNextFollowsTheAccountActuallySignedIn() throws {
        let sandbox = try Sandbox()
        for email in ["a@example.com", "b@example.com", "c@example.com"] {
            try sandbox.signIn(email: email, token: email)
            try sandbox.switcher.adoptCurrentAccount()
        }

        // Live session says a@, so the next one round is b@, not whatever
        // followed the last account the app itself switched to.
        try sandbox.signIn(email: "a@example.com", token: "a@example.com")
        try sandbox.switcher.switchToNext()

        XCTAssertEqual(sandbox.liveEmail, "b@example.com")
    }

    func testSwitchingToAnAccountWithNoSavedSessionChangesNothing() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "live@example.com", token: "live-token")
        try sandbox.switcher.adoptCurrentAccount()

        // A roster entry whose saved halves were never written.
        var roster = try sandbox.switcher.roster()
        let ghost = Profile(email: "ghost@example.com")
        roster.profiles.append(ghost)
        try sandbox.vault.save(roster)

        XCTAssertThrowsError(try sandbox.switcher.activate(ghost.id))
        XCTAssertEqual(sandbox.liveEmail, "live@example.com")
        XCTAssertEqual(sandbox.liveToken, "live-token")
    }

    func testSwitchingPreservesKeysTheAppDoesNotUnderstand() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "first@example.com")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com")
        try sandbox.switcher.adoptCurrentAccount()

        let first = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "first@example.com"))
        try sandbox.switcher.activate(first.id)

        let written = try Data(contentsOf: sandbox.session.settingsURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertNotNil(root["somethingJanusDoesNotKnowAbout"],
                        "the settings file belongs to another program and must come back whole")
    }

    func testRemovingDropsTheSavedSession() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "gone@example.com")
        try sandbox.switcher.adoptCurrentAccount()

        let profile = try XCTUnwrap(sandbox.switcher.roster().profiles.first)
        try sandbox.switcher.remove(profile.id)

        let roster = try sandbox.switcher.roster()
        XCTAssertTrue(roster.profiles.isEmpty)
        XCTAssertNil(roster.activeID)
        XCTAssertFalse(sandbox.vault.hasSession(for: profile.id))
    }

    func testRemovingLeavesTheSignedInSessionAlone() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "gone@example.com", token: "still-here")
        try sandbox.switcher.adoptCurrentAccount()

        let profile = try XCTUnwrap(sandbox.switcher.roster().profiles.first)
        try sandbox.switcher.remove(profile.id)

        XCTAssertEqual(sandbox.liveToken, "still-here")
        XCTAssertEqual(sandbox.liveEmail, "gone@example.com")
    }

    func testReorderingSurvivesAReload() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "first@example.com")
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com")
        try sandbox.switcher.adoptCurrentAccount()

        let second = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "second@example.com"))
        try sandbox.switcher.reorder(second.id, by: -1)

        XCTAssertEqual(try sandbox.switcher.roster().profiles.map(\.email),
                       ["second@example.com", "first@example.com"])
    }

    func testUsageComesFromTheLiveFileForTheActiveAccount() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "busy@example.com", usagePercent: 60)
        try sandbox.switcher.adoptCurrentAccount()

        let profile = try XCTUnwrap(sandbox.switcher.roster().profiles.first)
        let usage = try XCTUnwrap(sandbox.switcher.usage(for: profile, isActive: true))
        XCTAssertEqual(usage.fiveHour?.percentUsed, 60)
        XCTAssertEqual(usage.sevenDay?.percentUsed, 30)
        XCTAssertEqual(usage.breakdown.first?.label, "Claude Code")
    }

    func testUsageForASavedAccountComesFromItsSnapshot() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "first@example.com", usagePercent: 80)
        try sandbox.switcher.adoptCurrentAccount()
        try sandbox.signIn(email: "second@example.com", usagePercent: 10)
        try sandbox.switcher.adoptCurrentAccount()

        let first = try XCTUnwrap(sandbox.switcher.roster().profile(withEmail: "first@example.com"))
        let usage = try XCTUnwrap(sandbox.switcher.usage(for: first, isActive: false))
        XCTAssertEqual(usage.fiveHour?.percentUsed, 80)
    }

    func testTidyRemovesSettingsForAccountsNoLongerListed() throws {
        let sandbox = try Sandbox()
        try sandbox.signIn(email: "kept@example.com")
        try sandbox.switcher.adoptCurrentAccount()

        let stray = UUID()
        try sandbox.vault.store(StoredSession(credentials: Data("x".utf8),
                                              settings: sandbox.settings(email: "stray@example.com")),
                                for: stray)

        let outcome = try sandbox.switcher.tidy()
        XCTAssertTrue(outcome.headline.contains("1"))
        XCTAssertNil(sandbox.vault.storedSettings(for: stray))

        let kept = try XCTUnwrap(sandbox.switcher.roster().profiles.first)
        XCTAssertTrue(sandbox.vault.hasSession(for: kept.id))
    }
}
