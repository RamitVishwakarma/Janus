import Foundation
import XCTest
@testable import JanusCore

/// `Session.current` has to find the live session on a Mac that may carry the
/// leavings of more than one Claude Code version: two settings files, or a token
/// filed under an account name a later release stopped using. These cover the
/// choices it makes when the machine is not the tidy single-version case.
final class SessionTests: XCTestCase {

    private let service = Session.credentialService
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-session-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var nested: URL { home.appendingPathComponent(".claude/.claude.json") }
    private var legacy: URL { home.appendingPathComponent(".claude.json") }

    private func write(_ json: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func current(user: String, secrets: SecretStore) -> Session {
        Session.current(home: home, user: user, fileManager: .default, secrets: secrets)
    }

    // MARK: - Which settings file is the live one

    /// Both files exist but only one names an account; the account is what makes
    /// a file the live one, not where it sits. This is the regression: reaching
    /// for the empty nested file reads as "nobody is signed in."
    func testPrefersTheSettingsFileThatNamesAnAccount() throws {
        try write(["numStartups": 3], to: nested)
        try write(["oauthAccount": ["emailAddress": "live@example.com"]], to: legacy)

        let session = current(user: "tester", secrets: MemorySecretStore())

        XCTAssertEqual(session.settingsURL, legacy)
    }

    /// The nested file is preferred purely on location only when neither file
    /// names an account — a fresh or signed-out machine, where either choice is
    /// as good as the other and the old rule stands.
    func testFallsBackToTheNestedFileWhenNeitherNamesAnAccount() throws {
        try write(["numStartups": 1], to: nested)
        try write(["numStartups": 2], to: legacy)

        let session = current(user: "tester", secrets: MemorySecretStore())

        XCTAssertEqual(session.settingsURL, nested)
    }

    // MARK: - Which keychain account holds the token

    /// The token exists, but under the service name rather than the login name —
    /// the shape a current Claude Code writes. Assuming the login name here is
    /// indistinguishable from finding nothing at all.
    func testFindsTheTokenFiledUnderTheServiceName() throws {
        let store = MemorySecretStore(seed: [
            SecretAddress(service: service, account: service): Data("token".utf8)
        ])

        let session = current(user: "someone-else", secrets: store)

        XCTAssertEqual(session.credentials, SecretAddress(service: service, account: service))
    }

    /// When the login-name entry is the one that exists, it wins — the layout
    /// older versions wrote, still in use, must keep resolving to itself.
    func testPrefersTheLoginNameWhenThatIsWhereTheTokenIs() throws {
        let store = MemorySecretStore(seed: [
            SecretAddress(service: service, account: "tester"): Data("token".utf8)
        ])

        let session = current(user: "tester", secrets: store)

        XCTAssertEqual(session.credentials, SecretAddress(service: service, account: "tester"))
    }

    /// Nothing is signed in, so there is no entry to find. The address falls back
    /// to the service name — what a later sign-in will write — so the entry it
    /// creates is the one the next look finds.
    func testFallsBackToTheServiceNameWhenSignedOut() throws {
        let session = current(user: "tester", secrets: MemorySecretStore())

        XCTAssertEqual(session.credentials, SecretAddress(service: service, account: service))
    }
}
