import Foundation
import XCTest
@testable import JanusCore

/// A throwaway home directory plus an in-memory keychain, so a test can exercise
/// the real code without touching the machine running it.
final class Sandbox {

    let home: URL
    let secrets = MemorySecretStore()
    let vault: Vault
    let session: Session
    let switcher: Switcher

    init(file: StaticString = #filePath, line: UInt = #line) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        vault = Vault(root: home.appendingPathComponent("vault"), secrets: secrets)
        session = Session(credentials: SecretAddress(service: "Claude Code-credentials",
                                                     account: "tester"),
                          settingsURL: home.appendingPathComponent(".claude.json"))
        switcher = Switcher(vault: vault, session: session, secrets: secrets)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// Puts an account into the live slot, as if it had just been signed in.
    func signIn(email: String, token: String = "token", usagePercent: Int? = nil) throws {
        try secrets.write(Data(token.utf8), to: session.credentials)
        try settings(email: email, usagePercent: usagePercent).write(to: session.settingsURL)
    }

    func signOut() throws {
        try? FileManager.default.removeItem(at: session.settingsURL)
        try secrets.remove(session.credentials)
    }

    /// Makes the live keychain entry unreadable, the way macOS leaves it when
    /// its permission prompt is declined or never answered.
    func refuseLiveKeychain() {
        secrets.refuseReads(of: session.credentials)
    }

    func allowLiveKeychain() {
        secrets.allowReads(of: session.credentials)
    }

    var liveToken: String? {
        (try? secrets.read(session.credentials)).map { String(decoding: $0, as: UTF8.self) }
    }

    var liveEmail: String? {
        switcher.liveSettings()?.email
    }

    func settings(email: String, usagePercent: Int? = nil) -> Data {
        var root: [String: Any] = [
            "oauthAccount": ["emailAddress": email, "accountUuid": UUID().uuidString],
            "somethingJanusDoesNotKnowAbout": ["keep": true]
        ]
        if let usagePercent {
            root["cachedUsageUtilization"] = [
                "fetchedAtMs": Date().timeIntervalSince1970 * 1000,
                "utilization": [
                    "five_hour": ["utilization": usagePercent,
                                  "resets_at": "2030-01-01T00:00:00Z"],
                    "seven_day": ["utilization": usagePercent / 2,
                                  "resets_at": "2030-01-02T00:00:00Z"],
                    "seven_day_breakdown": ["rows": [["display_name": "Claude Code",
                                                      "percent": 97]]]
                ]
            ]
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }
}
