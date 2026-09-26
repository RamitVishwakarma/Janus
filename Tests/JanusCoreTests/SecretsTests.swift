import XCTest
@testable import JanusCore

/// The parts of `SystemKeychain` that do not need a keychain: how `security`'s
/// output is read back, and how its exit codes are named.
final class SecretsTests: XCTestCase {

    private let address = SecretAddress(service: "Claude Code-credentials", account: "tester")

    func testPlainOutputComesBackAsItself() {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc"}}"#
        XCTAssertEqual(SystemKeychain.decode(json + "\n"), Data(json.utf8))
    }

    func testHexOutputIsDecoded() {
        // What `security` prints instead when the payload is not all printable
        // ASCII: the same bytes, written out as hex.
        let payload = Data(#"{"a":"é"}"#.utf8)
        XCTAssertEqual(SystemKeychain.decode(SystemKeychain.hex(payload) + "\n"), payload)
    }

    func testAPayloadThatLooksLikeHexIsStillTakenAsHex() {
        // The ambiguity is real but harmless here: what Janus stores is JSON,
        // which always carries braces and quotes, so it can never be mistaken
        // for the encoded form.
        XCTAssertEqual(SystemKeychain.decode("abcdef\n"), Data([0xab, 0xcd, 0xef]))
        XCTAssertEqual(SystemKeychain.decode("abcde\n"), Data("abcde".utf8),
                       "an odd number of digits cannot be hex")
        XCTAssertEqual(SystemKeychain.decode("abcdeg\n"), Data("abcdeg".utf8),
                       "g is not a hex digit")
    }

    func testEveryPayloadSurvivesARoundTripThroughHex() {
        for text in [#"{"token":"sk-ant-oat01-A/B+C="}"#, "é→ünïcode", "", "0123456789abcdef"] {
            let payload = Data(text.utf8)
            XCTAssertEqual(SystemKeychain.decode(SystemKeychain.hex(payload)), payload, text)
        }
    }

    func testExitCodesAreNamed() {
        // `security` exits with the low byte of the OSStatus it failed on.
        XCTAssertEqual(SystemKeychain.error(forExit: 44, at: address), .notFound(address))
        XCTAssertEqual(SystemKeychain.error(forExit: 128, at: address), .accessDenied(address))
        XCTAssertEqual(SystemKeychain.error(forExit: 51, at: address), .accessDenied(address))
        XCTAssertEqual(SystemKeychain.error(forExit: 36, at: address), .accessDenied(address))
        XCTAssertEqual(SystemKeychain.error(forExit: 2, at: address), .unexpected(address, 2))
    }
}
