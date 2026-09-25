import AppKit
import Foundation
import SwiftUI
import SwitchboardCore

/// The cache side of the window: what is on disk, what is safe to clear, and
/// what was cleared last time.
@MainActor
final class CachesModel: ObservableObject {

    @Published private(set) var readings: [CacheReading] = []
    @Published var chosen: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var report: ReclaimReport?

    /// Total of everything that could be cleared right now, which is the number
    /// worth putting in the menu bar.
    var clearableBytes: Int64 {
        readings.filter { !$0.isBlocked }.reduce(0) { $0 + $1.bytes }
    }

    var chosenBytes: Int64 {
        readings.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var blockedCount: Int {
        readings.filter(\.isBlocked).count
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        report = nil

        let running = Self.runningApps()
        Task {
            let fresh = await CacheSurvey.scan(runningApps: running)
            readings = fresh

            // Open with everything clearable already ticked: the common case is
            // clearing all of it, and unticking is easier than hunting.
            let available = Set(fresh.filter { !$0.isBlocked }.map(\.id))
            chosen = chosen.isEmpty ? available : chosen.intersection(available)
            isScanning = false
        }
    }

    func clear() {
        let selected = readings.filter { chosen.contains($0.id) && !$0.isBlocked }
        guard !selected.isEmpty else { return }

        report = Reclaimer.trash(selected)
        chosen = []
        scan()
    }

    func isChosen(_ reading: CacheReading) -> Bool {
        chosen.contains(reading.id)
    }

    func choose(_ reading: CacheReading, _ isOn: Bool) {
        if isOn { chosen.insert(reading.id) } else { chosen.remove(reading.id) }
    }

    func selectAll() {
        chosen = Set(readings.filter { !$0.isBlocked }.map(\.id))
    }

    func selectNone() {
        chosen = []
    }

    /// Asks an app to quit the same way its own menu would. Never forced —
    /// unsaved work is the app's business, not this one's.
    func quitOwner(of reading: CacheReading) {
        guard let bundleID = reading.entry.ownerBundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .forEach { _ = $0.terminate() }
    }

    private static func runningApps() -> [String: String] {
        var found: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            found[id] = app.localizedName ?? id
        }
        return found
    }
}
