import XCTest
@testable import SwitchboardCore

final class VaultTests: XCTestCase {

    func testAnEmptyVaultReadsAsAnEmptyRoster() throws {
        let sandbox = try Sandbox()
        XCTAssertTrue(try sandbox.vault.loadRoster().profiles.isEmpty)
    }

    func testRosterSurvivesARoundTrip() throws {
        let sandbox = try Sandbox()
        let profile = Profile(email: "sam@example.com")
        try sandbox.vault.save(Roster(profiles: [profile], activeID: profile.id))

        let reloaded = try sandbox.vault.loadRoster()
        XCTAssertEqual(reloaded.profiles.map(\.email), ["sam@example.com"])
        XCTAssertEqual(reloaded.activeID, profile.id)
        XCTAssertEqual(reloaded.schema, Roster.currentSchema)
    }

    func testACorruptRosterIsReportedRatherThanIgnored() throws {
        let sandbox = try Sandbox()
        try sandbox.vault.save(Roster())
        try Data("not json".utf8).write(to: sandbox.vault.root.appendingPathComponent("roster.json"))

        XCTAssertThrowsError(try sandbox.vault.loadRoster())
    }

    func testStoredSessionsComeBackUnchanged() throws {
        let sandbox = try Sandbox()
        let id = UUID()
        let session = StoredSession(credentials: Data("secret".utf8),
                                    settings: Data(#"{"a":1}"#.utf8))

        try sandbox.vault.store(session, for: id)
        XCTAssertEqual(try sandbox.vault.session(for: id), session)
    }

    func testASessionNeedsBothHalvesToCount() throws {
        let sandbox = try Sandbox()
        let id = UUID()
        try sandbox.vault.store(StoredSession(credentials: Data("s".utf8),
                                              settings: Data("{}".utf8)), for: id)
        XCTAssertTrue(sandbox.vault.hasSession(for: id))

        try sandbox.secrets.remove(sandbox.vault.credentialAddress(for: id))
        XCTAssertFalse(sandbox.vault.hasSession(for: id),
                       "settings without credentials cannot restore a session")
    }

    func testDiscardingRemovesBothHalves() throws {
        let sandbox = try Sandbox()
        let id = UUID()
        try sandbox.vault.store(StoredSession(credentials: Data("s".utf8),
                                              settings: Data("{}".utf8)), for: id)

        sandbox.vault.discardSession(for: id)

        XCTAssertFalse(sandbox.vault.hasSession(for: id))
        XCTAssertNil(sandbox.vault.storedSettings(for: id))
        XCTAssertTrue(sandbox.secrets.addresses.isEmpty)
    }

    func testSavedSettingsAreReadableOnlyByTheirOwner() throws {
        let sandbox = try Sandbox()
        let id = UUID()
        try sandbox.vault.store(StoredSession(credentials: Data("s".utf8),
                                              settings: Data("{}".utf8)), for: id)

        let attributes = try FileManager.default
            .attributesOfItem(atPath: sandbox.vault.settingsURL(for: id).path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func testStrandedFilesAreThoseWithNoAccount() throws {
        let sandbox = try Sandbox()
        let kept = Profile(email: "kept@example.com")
        let stray = UUID()

        try sandbox.vault.store(StoredSession(credentials: Data("a".utf8),
                                              settings: Data("{}".utf8)), for: kept.id)
        try sandbox.vault.store(StoredSession(credentials: Data("b".utf8),
                                              settings: Data("{}".utf8)), for: stray)

        let stranded = sandbox.vault.strandedSettingsFiles(roster: Roster(profiles: [kept]))
        XCTAssertEqual(stranded.map { $0.lastPathComponent },
                       ["\(stray.uuidString).json"])
    }
}
