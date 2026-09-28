import XCTest
@testable import JanusCore

/// Where `Session.current` looks for the live session, against a throwaway home
/// directory laid out the ways real Macs are.
final class SessionTests: XCTestCase {

    private var home: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-session-tests/\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home.appendingPathComponent(".claude"),
                                        withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: home)
    }

    // MARK: - Helpers

    private func write(_ json: [String: Any], to relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func signedIn(_ email: String) -> [String: Any] {
        ["oauthAccount": ["emailAddress": email, "accountUuid": UUID().uuidString],
         "numStartups": 12]
    }

    /// The shape of the file a Claude Code started with `CLAUDE_CONFIG_DIR`
    /// pointed at `~/.claude` leaves behind when nobody signs in through it.
    private let cachesOnly: [String: Any] = [
        "cachedGrowthBookFeatures": ["some_flag": true],
        "userID": "abc123",
        "firstStartTime": "2026-09-28T15:07:00.000Z"
    ]

    private func current(environment: [String: String] = ["USER": "tester"]) -> Session {
        Session.current(home: home, user: "tester", environment: environment,
                        fileManager: fileManager)
    }

    private func email(in session: Session) -> String? {
        fileManager.contents(atPath: session.settingsURL.path)
            .map(SessionSettings.init(raw:))?.email
    }

    // MARK: - Settings file

    func testDefaultInstallReadsTheFileInHome() throws {
        try write(signedIn("a@example.com"), to: ".claude.json")

        let session = current()

        XCTAssertEqual(session.settingsURL.lastPathComponent, ".claude.json")
        XCTAssertEqual(session.settingsURL.deletingLastPathComponent().standardizedFileURL,
                       home.standardizedFileURL)
        XCTAssertEqual(session.credentials.service, "Claude Code-credentials")
        XCTAssertEqual(email(in: session), "a@example.com")
    }

    /// The bug this file exists for: a stray `~/.claude/.claude.json` with no
    /// account in it used to win over the real, signed-in `~/.claude.json`.
    func testStrayNestedFileDoesNotHideTheSignedInAccount() throws {
        try write(signedIn("a@example.com"), to: ".claude.json")
        try write(cachesOnly, to: ".claude/.claude.json")

        let session = current()

        XCTAssertEqual(email(in: session), "a@example.com")
        XCTAssertEqual(session.credentials.service, "Claude Code-credentials")
    }

    func testConfigDirFromTheEnvironmentMovesBothHalves() throws {
        try write(signedIn("a@example.com"), to: ".claude.json")
        try write(signedIn("work@example.com"), to: "work-claude/.claude.json")
        let directory = home.appendingPathComponent("work-claude").path

        let session = current(environment: ["USER": "tester", "CLAUDE_CONFIG_DIR": directory])

        XCTAssertEqual(email(in: session), "work@example.com")
        XCTAssertEqual(session.credentials.service,
                       "Claude Code-credentials-\(Session.configDirectoryHash(directory))")
    }

    /// `CLAUDE_CONFIG_DIR=~/.claude` set in a shell the app never sees: the only
    /// signed-in file is the nested one, and its tokens are under the hashed name.
    func testNestedFileIsUsedWhenItIsTheOnlyOneSignedIn() throws {
        try write(cachesOnly, to: ".claude.json")
        try write(signedIn("a@example.com"), to: ".claude/.claude.json")

        let session = current()

        XCTAssertEqual(email(in: session), "a@example.com")
        let directory = home.appendingPathComponent(".claude").path
        XCTAssertEqual(session.credentials.service,
                       "Claude Code-credentials-\(Session.configDirectoryHash(directory))")
    }

    func testPreOneConfigFileTakesPrecedence() throws {
        try write(signedIn("old@example.com"), to: ".claude/.config.json")
        try write(signedIn("a@example.com"), to: ".claude.json")

        let session = current()

        XCTAssertEqual(session.settingsURL.lastPathComponent, ".config.json")
        XCTAssertEqual(email(in: session), "old@example.com")
        XCTAssertEqual(session.credentials.service, "Claude Code-credentials")
    }

    func testNothingSignedInPointsWhereClaudeCodeWouldWrite() throws {
        try write(cachesOnly, to: ".claude/.claude.json")

        let session = current()

        XCTAssertEqual(session.settingsURL.lastPathComponent, ".claude.json")
        XCTAssertEqual(session.settingsURL.deletingLastPathComponent().standardizedFileURL,
                       home.standardizedFileURL)
        XCTAssertEqual(session.credentials.service, "Claude Code-credentials")
    }

    // MARK: - Keychain address

    func testConfigDirectoryHashMatchesClaudeCode() {
        // sha256("/Users/tester/.claude"), first eight hex digits, as Claude Code
        // computes it for the keychain service name.
        XCTAssertEqual(Session.configDirectoryHash("/Users/tester/.claude"), "ee16a9f4")
        XCTAssertEqual(Session.configDirectoryHash("/Users/tester/work-claude"), "95ee8f90")
    }

    func testKeychainAccountPrefersUserFromTheEnvironment() {
        XCTAssertEqual(Session.keychainAccount(environment: ["USER": "wojtek"], user: "other"),
                       "wojtek")
        XCTAssertEqual(Session.keychainAccount(environment: [:], user: "other"), "other")
    }

    func testKeychainAccountFallsBackForNamesClaudeCodeRejects() {
        XCTAssertEqual(Session.keychainAccount(environment: ["USER": "jan kowalski"], user: "x"),
                       Session.fallbackAccount)
        XCTAssertEqual(Session.keychainAccount(environment: [:], user: "zażółć"),
                       Session.fallbackAccount)
    }
}
