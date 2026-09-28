import XCTest
@testable import JanusCore

/// Which settings file `Session.current` treats as live, against a throwaway home.
final class SessionTests: XCTestCase {

    private var home: URL!

    private var nested: URL { home.appendingPathComponent(".claude/.claude.json") }
    private var legacy: URL { home.appendingPathComponent(".claude.json") }

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url)
    }

    private let signedIn = #"{"oauthAccount":{"emailAddress":"sam@example.com"}}"#
    private let stub = #"{"machineID":"abc","pluginUsage":{}}"#

    private var chosen: URL { Session.current(home: home, user: "tester").settingsURL }

    func testAFreshInstallGetsTheHomeDirectoryFile() {
        XCTAssertEqual(chosen, legacy)
    }

    func testTheOnlyFileIsTheLiveOne() throws {
        try write(signedIn, to: nested)
        XCTAssertEqual(chosen, nested)
    }

    func testAStubInsideDotClaudeDoesNotHideTheSignedInSession() throws {
        try write(stub, to: nested)
        try write(signedIn, to: legacy)
        XCTAssertEqual(chosen, legacy)
    }

    func testTheNestedFileWinsWhenBothNameAnAccount() throws {
        try write(signedIn, to: nested)
        try write(signedIn, to: legacy)
        XCTAssertEqual(chosen, nested)
    }

    func testTheNestedFileWinsWhenNeitherNamesAnAccount() throws {
        try write(stub, to: nested)
        try write(stub, to: legacy)
        XCTAssertEqual(chosen, nested)
    }
}
