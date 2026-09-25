import XCTest
@testable import JanusCore

/// Reordering the rotation must never cost an account anything.
///
/// Worth pinning down explicitly: accounts are keyed by UUID precisely so that
/// their position is not part of how they are stored. A future change that keys
/// storage off position again would be a data-loss bug, and these tests are what
/// should catch it.
final class ReorderTests: XCTestCase {

    /// Three accounts, each with credentials and settings of its own.
    private func populated() throws -> Sandbox {
        let sandbox = try Sandbox()
        for (email, token) in [("alpha@example.com", "tok-alpha"),
                               ("beta@example.com", "tok-beta"),
                               ("gamma@example.com", "tok-gamma")] {
            try sandbox.signIn(email: email, token: token, usagePercent: token.count)
            try sandbox.switcher.adoptCurrentAccount()
        }
        return sandbox
    }

    /// Every account's stored session, as something comparable.
    private func storedSessions(_ sandbox: Sandbox) throws -> [String: StoredSession] {
        var found: [String: StoredSession] = [:]
        for profile in try sandbox.switcher.roster().profiles {
            found[profile.email] = try sandbox.vault.session(for: profile.id)
        }
        return found
    }

    func testReorderingLeavesEveryStoredSessionByteIdentical() throws {
        let sandbox = try populated()
        let before = try storedSessions(sandbox)

        let roster = try sandbox.switcher.roster()
        try sandbox.switcher.reorder(roster.profiles[2].id, by: -1)
        try sandbox.switcher.reorder(roster.profiles[0].id, by: 1)

        XCTAssertEqual(try storedSessions(sandbox), before)
    }

    func testReorderingDoesNotChangeWhichAccountIsActive() throws {
        let sandbox = try populated()
        let activeBefore = try sandbox.switcher.roster().activeID

        let roster = try sandbox.switcher.roster()
        try sandbox.switcher.reorder(roster.profiles[0].id, by: 1)

        XCTAssertEqual(try sandbox.switcher.roster().activeID, activeBefore)
        XCTAssertEqual(sandbox.liveEmail, "gamma@example.com")
        XCTAssertEqual(sandbox.liveToken, "tok-gamma")
    }

    func testMovingPastEitherEndChangesNothing() throws {
        let sandbox = try populated()
        let order = try sandbox.switcher.roster().profiles

        try sandbox.switcher.reorder(order[0].id, by: -1)
        try sandbox.switcher.reorder(order[2].id, by: 1)
        try sandbox.switcher.reorder(order[0].id, by: -99)

        XCTAssertEqual(try sandbox.switcher.roster().profiles.map(\.email),
                       order.map(\.email))
    }

    func testReorderingAnAccountThatIsNoLongerThereIsHarmless() throws {
        let sandbox = try populated()
        let order = try sandbox.switcher.roster().profiles.map(\.email)

        XCTAssertNoThrow(try sandbox.switcher.reorder(UUID(), by: 1))
        XCTAssertEqual(try sandbox.switcher.roster().profiles.map(\.email), order)
    }

    func testRepeatedReorderingNeverDropsOrDuplicatesAnAccount() throws {
        let sandbox = try populated()
        let expected = Set(["alpha@example.com", "beta@example.com", "gamma@example.com"])
        let before = try storedSessions(sandbox)

        // Offsets deliberately run off both ends of the list.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let roster = try sandbox.switcher.roster()
            guard let victim = roster.profiles.randomElement(using: &generator),
                  let offset = [-2, -1, 1, 2].randomElement(using: &generator)
            else { continue }
            try sandbox.switcher.reorder(victim.id, by: offset)

            let after = try sandbox.switcher.roster()
            XCTAssertEqual(after.profiles.count, 3)
            XCTAssertEqual(Set(after.profiles.map(\.email)), expected)
        }

        XCTAssertEqual(try storedSessions(sandbox), before)
    }

    func testSwitchingStillWorksAfterReordering() throws {
        let sandbox = try populated()

        let roster = try sandbox.switcher.roster()
        try sandbox.switcher.reorder(roster.profiles[2].id, by: -2)

        let alpha = try XCTUnwrap(try sandbox.switcher.roster().profile(withEmail: "alpha@example.com"))
        try sandbox.switcher.activate(alpha.id)

        XCTAssertEqual(sandbox.liveEmail, "alpha@example.com")
        XCTAssertEqual(sandbox.liveToken, "tok-alpha")
    }

    func testUsageFiguresSurviveReordering() throws {
        let sandbox = try populated()
        let roster = try sandbox.switcher.roster()
        try sandbox.switcher.reorder(roster.profiles[1].id, by: -1)

        let beta = try XCTUnwrap(try sandbox.switcher.roster().profile(withEmail: "beta@example.com"))
        let usage = try XCTUnwrap(sandbox.switcher.usage(for: beta, isActive: false))
        XCTAssertEqual(usage.fiveHour?.percentUsed, "tok-beta".count)
    }

    func testTheRotationFollowsTheOrderOnScreen() throws {
        let sandbox = try populated()

        // Put gamma, the signed-in account, at the front.
        let gamma = try XCTUnwrap(try sandbox.switcher.roster().profile(withEmail: "gamma@example.com"))
        try sandbox.switcher.reorder(gamma.id, by: -1)
        try sandbox.switcher.reorder(gamma.id, by: -1)

        try sandbox.switcher.switchToNext()

        // Whatever now sits second in the list is where a plain switch lands.
        XCTAssertEqual(sandbox.liveEmail, "alpha@example.com")
    }
}
