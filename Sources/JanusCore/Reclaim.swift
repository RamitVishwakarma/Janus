import Foundation

/// The rule about what may be cleared.
///
/// Two conditions, both of which have to hold: the path is inside the home
/// directory, and it is not one of the directories that everything else lives
/// under. The second is what turns a typo in the catalogue into a refusal rather
/// than a very bad afternoon.
public enum TrashPolicy {

    /// Directories that are never a valid target, even though they sit in the
    /// home directory. Relative, matched exactly, so a path *inside* any of them
    /// is fine, which is the point.
    public static let guarded: Set<String> = [
        "", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        "Public", "Applications", "Library", "Library/Caches",
        "Library/Application Support", "Library/Developer", "Library/Developer/Xcode",
        ".ssh", ".gnupg", ".config", ".cache", ".claude", ".local", "go", "Projects"
    ]

    public static func permits(_ url: URL,
                               home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        let target = url.standardizedFileURL.path
        let base = home.standardizedFileURL.path

        guard target.hasPrefix(base + "/") else { return false }

        let relative = String(target.dropFirst(base.count + 1))
        guard !relative.isEmpty, !relative.hasPrefix("..") else { return false }

        return !guarded.contains(relative)
    }
}

/// One catalogue entry as it stands on this Mac right now.
public struct CacheReading: Identifiable, Equatable {
    public let entry: CacheEntry
    public let bytes: Int64
    /// Name of the owning app if it happens to be open, e.g. "Visual Studio Code".
    public let runningOwner: String?

    public var id: String { entry.id }

    /// Held open by the app that owns it. Clearing a cache underneath a running
    /// app is a good way to confuse the app, so these are shown but not offered.
    public var isBlocked: Bool { runningOwner != nil && !entry.clearableWhileRunning }

    public init(entry: CacheEntry, bytes: Int64, runningOwner: String? = nil) {
        self.entry = entry
        self.bytes = bytes
        self.runningOwner = runningOwner
    }
}

/// Measures the catalogue.
public enum CacheSurvey {

    /// - Parameter runningApps: bundle identifier to display name, for apps open
    ///   right now. Passed in rather than looked up, so this file has no opinion
    ///   about AppKit and can be tested without one.
    public static func scan(
        catalog: [CacheEntry] = CacheEntry.catalog,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        runningApps: [String: String] = [:]
    ) async -> [CacheReading] {
        let sizes = await withTaskGroup(of: (String, Int64).self) { group -> [String: Int64] in
            for entry in catalog {
                let url = entry.url(home: home)
                group.addTask { (entry.id, DiskUsage.bytes(at: url)) }
            }
            var collected: [String: Int64] = [:]
            for await (id, bytes) in group { collected[id] = bytes }
            return collected
        }

        return catalog
            .compactMap { entry -> CacheReading? in
                guard let bytes = sizes[entry.id], bytes > 0 else { return nil }
                let owner = entry.ownerBundleID.flatMap { runningApps[$0] }
                return CacheReading(entry: entry, bytes: bytes, runningOwner: owner)
            }
            .sorted { $0.bytes > $1.bytes }
    }
}

public struct ReclaimReport: Equatable {
    public var freedBytes: Int64 = 0
    public var cleared: [String] = []
    public var refused: [String] = []

    public var summary: String {
        guard !cleared.isEmpty else {
            return refused.isEmpty ? "Nothing to clear." : "Nothing could be cleared."
        }
        var text = "Moved \(DiskUsage.describe(freedBytes)) to the Trash."
        if !refused.isEmpty {
            text += "\n\nLeft alone:\n• " + refused.joined(separator: "\n• ")
        }
        return text
    }
}

/// Clears caches by moving them to the Trash.
///
/// Nothing is deleted outright. Getting this wrong should cost a drag out of the
/// Trash, not a redownload, and on a bad day, not a restore from backup.
public enum Reclaimer {

    public static func trash(_ readings: [CacheReading],
                             home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                             fileManager: FileManager = .default) -> ReclaimReport {
        var report = ReclaimReport()

        for reading in readings {
            let url = reading.entry.url(home: home)

            guard !reading.isBlocked else {
                report.refused.append("\(reading.entry.name), \(reading.runningOwner ?? "its app") is running")
                continue
            }
            guard TrashPolicy.permits(url, home: home) else {
                report.refused.append("\(reading.entry.name), not a path this app will touch")
                continue
            }

            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                report.freedBytes += reading.bytes
                report.cleared.append(reading.entry.name)
            } catch {
                // Almost always macOS privacy protection on a folder the app has
                // not been granted, which Full Disk Access fixes.
                report.refused.append("\(reading.entry.name), \(error.localizedDescription)")
            }
        }

        return report
    }
}
