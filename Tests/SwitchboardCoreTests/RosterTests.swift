import XCTest
@testable import SwitchboardCore

final class RosterTests: XCTestCase {

    private func roster(_ emails: [String]) -> Roster {
        Roster(profiles: emails.map { Profile(email: $0) })
    }

    func testShortNameDropsTheDomain() {
        XCTAssertEqual(Profile(email: "sam@example.com").shortName, "sam")
    }

    func testShortNameFallsBackWhenThereIsNoDomain() {
        XCTAssertEqual(Profile(email: "sam").shortName, "sam")
    }

    func testNextWrapsAroundTheRotation() {
        var roster = self.roster(["a@x.com", "b@x.com", "c@x.com"])
        roster.activeID = roster.profiles[2].id
        XCTAssertEqual(roster.next?.email, "a@x.com")
    }

    func testNextIsTheFollowingAccount() {
        var roster = self.roster(["a@x.com", "b@x.com", "c@x.com"])
        roster.activeID = roster.profiles[0].id
        XCTAssertEqual(roster.next?.email, "b@x.com")
    }

    func testNextPicksAnythingElseWhenNothingIsActive() {
        let roster = self.roster(["a@x.com", "b@x.com"])
        XCTAssertEqual(roster.next?.email, "a@x.com")
    }

    func testNextIsNilForASingleAccountAlreadyActive() {
        var roster = self.roster(["only@x.com"])
        roster.activeID = roster.profiles[0].id
        XCTAssertNil(roster.next)
    }

    func testLookupByEmailIgnoresCase() {
        let roster = self.roster(["Sam@Example.com"])
        XCTAssertNotNil(roster.profile(withEmail: "sam@example.com"))
    }

    func testMoveReordersWithinBounds() {
        var roster = self.roster(["a@x.com", "b@x.com", "c@x.com"])
        roster.move(roster.profiles[2].id, by: -1)
        XCTAssertEqual(roster.profiles.map(\.email), ["a@x.com", "c@x.com", "b@x.com"])
    }

    func testTheLiveEmailOutranksTheRecordedActiveAccount() {
        var roster = self.roster(["a@x.com", "b@x.com"])
        roster.activeID = roster.profiles[0].id
        XCTAssertEqual(roster.active(signedInAs: "b@x.com")?.email, "b@x.com")
    }

    func testTheRecordedAccountIsUsedWhenNobodyIsSignedIn() {
        var roster = self.roster(["a@x.com", "b@x.com"])
        roster.activeID = roster.profiles[1].id
        XCTAssertEqual(roster.active(signedInAs: nil)?.email, "b@x.com")
    }

    func testAnUnknownLiveEmailFallsBackToTheRecord() {
        var roster = self.roster(["a@x.com"])
        roster.activeID = roster.profiles[0].id
        XCTAssertEqual(roster.active(signedInAs: "stranger@x.com")?.email, "a@x.com")
    }

    func testSuccessorWrapsAround() {
        let roster = self.roster(["a@x.com", "b@x.com", "c@x.com"])
        XCTAssertEqual(roster.successor(to: roster.profiles[2])?.email, "a@x.com")
    }

    func testMovePastTheEndIsIgnored() {
        var roster = self.roster(["a@x.com", "b@x.com"])
        roster.move(roster.profiles[1].id, by: 1)
        XCTAssertEqual(roster.profiles.map(\.email), ["a@x.com", "b@x.com"])
    }
}
