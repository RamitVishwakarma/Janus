import XCTest
@testable import JanusCore

final class UsageTests: XCTestCase {

    private func settings(_ json: String) -> SessionSettings {
        SessionSettings(raw: Data(json.utf8))
    }

    func testReadsTheSignedInEmail() {
        let parsed = settings(#"{"oauthAccount":{"emailAddress":"sam@example.com"}}"#)
        XCTAssertEqual(parsed.email, "sam@example.com")
        XCTAssertTrue(parsed.isSignedIn)
    }

    func testAnEmptyEmailDoesNotCountAsSignedIn() {
        XCTAssertFalse(settings(#"{"oauthAccount":{"emailAddress":""}}"#).isSignedIn)
    }

    func testUnparseableSettingsAreNotSignedIn() {
        XCTAssertFalse(settings("<html>nope</html>").isSignedIn)
    }

    func testUsageIsAbsentUntilTheAccountHasBeenUsed() {
        XCTAssertNil(settings(#"{"oauthAccount":{"emailAddress":"a@b.com"}}"#).usage)
    }

    func testReadsBothWindowsAndTheBreakdown() throws {
        let parsed = settings("""
            {"cachedUsageUtilization":{
              "fetchedAtMs": 1700000000000,
              "utilization": {
                "five_hour": {"utilization": 42, "resets_at": "2030-01-01T10:00:00Z"},
                "seven_day": {"utilization": 88, "resets_at": "2030-01-05T10:00:00.500Z"},
                "seven_day_breakdown": {"rows": [
                  {"display_name": "Claude Code", "percent": 97},
                  {"display_name": "Chats", "percent": 0}
                ]}
              }}}
            """)

        let usage = try XCTUnwrap(parsed.usage)
        XCTAssertEqual(usage.fiveHour?.percentUsed, 42)
        XCTAssertEqual(usage.sevenDay?.percentUsed, 88)
        XCTAssertNotNil(usage.sevenDay?.resetsAt, "fractional-second timestamps must parse too")
        XCTAssertEqual(usage.measuredAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(usage.breakdown.map(\.label), ["Claude Code"],
                       "a slice at zero percent is noise")
    }

    func testAWindowWithoutAPercentageIsSkipped() throws {
        let parsed = settings("""
            {"cachedUsageUtilization":{"utilization":{"five_hour":{"resets_at":"2030-01-01T00:00:00Z"}}}}
            """)
        let usage = try XCTUnwrap(parsed.usage)
        XCTAssertNil(usage.fiveHour)
        XCTAssertTrue(usage.isEmpty)
    }

    func testCountdownsReadAsDurations() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Elapsed.until(now.addingTimeInterval(3 * 3600 + 20 * 60), now: now),
                       "resets in 3h 20m")
        XCTAssertEqual(Elapsed.until(now.addingTimeInterval(2 * 86400), now: now),
                       "resets in 2d")
        XCTAssertEqual(Elapsed.until(now.addingTimeInterval(90), now: now), "resets in 1m")
        XCTAssertEqual(Elapsed.until(now.addingTimeInterval(-5), now: now), "resetting now")
        XCTAssertNil(Elapsed.until(nil))
    }

    func testAgesReadAsDurations() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Elapsed.since(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(Elapsed.since(now.addingTimeInterval(-3600), now: now), "1h ago")
        XCTAssertEqual(Elapsed.since(now.addingTimeInterval(-86400 * 3), now: now), "3d ago")
    }
}
