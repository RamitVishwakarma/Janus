import XCTest
@testable import JanusCore

final class CacheCatalogTests: XCTestCase {

    func testIdentifiersAreUnique() {
        let ids = CacheEntry.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryEntryIsDescribed() {
        for entry in CacheEntry.catalog {
            XCTAssertFalse(entry.name.isEmpty, "\(entry.id) needs a name")
            XCTAssertFalse(entry.note.isEmpty, "\(entry.id) needs an explanation")
        }
    }

    func testPathsAreRelativeToHome() {
        for entry in CacheEntry.catalog {
            XCTAssertFalse(entry.path.hasPrefix("/"), "\(entry.id) must not be absolute")
            XCTAssertFalse(entry.path.contains(".."), "\(entry.id) must not climb out")
        }
    }

    /// The catalogue is hand-written, so the guard against a bad entry has to be
    /// a test rather than a review.
    func testEveryEntryWouldBeAllowed() {
        let home = URL(fileURLWithPath: "/Users/tester")
        for entry in CacheEntry.catalog {
            XCTAssertTrue(TrashPolicy.permits(entry.url(home: home), home: home),
                          "\(entry.id) points somewhere clearing is not allowed")
        }
    }

    func testOwnedEntriesDeclareWhetherTheyAreSafeWhileOpen() {
        let owned = CacheEntry.catalog.filter { $0.ownerBundleID != nil }
        XCTAssertFalse(owned.isEmpty)
    }
}

final class TrashPolicyTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester")

    private func permits(_ path: String) -> Bool {
        TrashPolicy.permits(URL(fileURLWithPath: path), home: home)
    }

    func testAllowsACacheInsideHome() {
        XCTAssertTrue(permits("/Users/tester/Library/Caches/Homebrew"))
        XCTAssertTrue(permits("/Users/tester/.npm"))
    }

    func testRefusesAnythingOutsideHome() {
        XCTAssertFalse(permits("/Library/Caches"))
        XCTAssertFalse(permits("/tmp/whatever"))
        XCTAssertFalse(permits("/Users/someone-else/.npm"))
    }

    func testRefusesHomeItself() {
        XCTAssertFalse(permits("/Users/tester"))
        XCTAssertFalse(permits("/Users/tester/"))
    }

    func testRefusesTheDirectoriesEverythingElseLivesIn() {
        for path in ["Desktop", "Documents", "Downloads", "Library",
                     "Library/Caches", "Library/Application Support", ".ssh", ".claude"] {
            XCTAssertFalse(permits("/Users/tester/" + path), "~/\(path) must be refused")
        }
    }

    func testRefusesPathsThatClimbOut() {
        XCTAssertFalse(permits("/Users/tester/../root-cache"))
    }
}

final class DiskUsageTests: XCTestCase {

    func testReadsTheSizeFieldFromDu() {
        XCTAssertEqual(DiskUsage.kilobytes(fromDuOutput: "4096\t/Users/t/.npm\n"), 4096)
    }

    func testIgnoresExtraLines() {
        XCTAssertEqual(DiskUsage.kilobytes(fromDuOutput: "12\t/a\n34\t/b\n"), 12)
    }

    func testUnreadableOutputIsZero() {
        XCTAssertEqual(DiskUsage.kilobytes(fromDuOutput: ""), 0)
        XCTAssertEqual(DiskUsage.kilobytes(fromDuOutput: "du: no such file\n"), 0)
    }

    func testMissingDirectoriesMeasureZero() {
        XCTAssertEqual(DiskUsage.bytes(at: URL(fileURLWithPath: "/nope/not/here")), 0)
    }
}

final class ReclaimerTests: XCTestCase {

    func testBlockedEntriesAreLeftAlone() {
        let entry = CacheEntry(id: "x", name: "Editor cache", note: "n",
                               path: "Library/Caches/x",
                               ownerBundleID: "com.example.editor",
                               clearableWhileRunning: false)
        let reading = CacheReading(entry: entry, bytes: 10, runningOwner: "Editor")

        let report = Reclaimer.trash([reading], home: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertTrue(report.cleared.isEmpty)
        XCTAssertEqual(report.refused.count, 1)
        XCTAssertTrue(report.refused[0].contains("Editor is running"))
    }

    func testAGuardedPathIsRefusedEvenIfItReachesTheReclaimer() {
        let entry = CacheEntry(id: "oops", name: "Mistake", note: "n", path: "Documents")
        let reading = CacheReading(entry: entry, bytes: 99)

        let report = Reclaimer.trash([reading], home: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertEqual(report.refused.count, 1)
    }

    func testRealDirectoriesGoToTheTrash() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("janus-reclaim/\(UUID().uuidString)")
        let cache = home.appendingPathComponent("Library/Caches/example")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: cache.appendingPathComponent("file"))
        defer { try? FileManager.default.removeItem(at: home) }

        let entry = CacheEntry(id: "example", name: "Example", note: "n",
                               path: "Library/Caches/example")
        let report = Reclaimer.trash([CacheReading(entry: entry, bytes: 4)], home: home)

        XCTAssertEqual(report.cleared, ["Example"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(report.summary.contains("Trash"))
    }
}
