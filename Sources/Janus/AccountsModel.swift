import AppKit
import Foundation
import SwiftUI
import JanusCore

/// One account's figures and where they came from, which is what decides how the
/// row is allowed to describe itself.
struct Reading: Equatable {
    let usage: Usage
    let source: UsageSource
}

/// Everything the interface knows about accounts, and the only place it asks for
/// anything to change.
///
/// Reading off the disk is cheap and happens often: it touches files and asks the
/// keychain whether entries exist, but never asks for a secret, so the window
/// redrawing itself can never raise a permission prompt. Only a switch, or a
/// fetch, does that.
@MainActor
final class AccountsModel: ObservableObject {

    /// How often the window re-reads the disk and moves its clocks on.
    ///
    /// Half a minute is chosen against what is on screen rather than against what
    /// it costs: the finest thing shown is a countdown in whole minutes, so this
    /// is the longest interval that can never show a minute that has passed.
    static let tick: TimeInterval = 30

    @Published private(set) var roster = Roster()
    @Published private(set) var readings: [UUID: Reading] = [:]
    @Published private(set) var restorable: Set<UUID> = []
    @Published private(set) var signedInEmail: String?
    @Published private(set) var isWorking = false
    @Published private(set) var outcome: Outcome?
    @Published private(set) var failure: String?

    /// The moment every countdown and every "has this window reset yet" is
    /// measured against.
    ///
    /// Published, and therefore the reason the window changes on its own. Reading
    /// the clock inside a view instead would be read once, at the moment the row
    /// was drawn, and a row drawn at nine o'clock would still be saying "resets in
    /// 2h 22m" at midnight.
    @Published private(set) var now = Date()

    /// Figures fetched from Anthropic, kept apart from what the disk says so that
    /// re-reading the disk cannot quietly undo them.
    private var fetched: [UUID: Usage] = [:]

    private let switcher: Switcher
    private var ticker: Timer?

    init(switcher: Switcher = Switcher()) {
        self.switcher = switcher
        reload()
        startTicking()
    }

    deinit { ticker?.invalidate() }

    // MARK: - Derived state

    var profiles: [Profile] { roster.profiles }

    /// The account signed in right now. The settings file wins over the roster's
    /// record of it, so signing in outside the app still shows up correctly.
    var active: Profile? { roster.active(signedInAs: signedInEmail) }

    var next: Profile? { roster.successor(to: active) }

    /// True when the signed-in account is one Janus already knows about.
    var currentAccountIsManaged: Bool {
        guard let signedInEmail else { return false }
        return roster.profile(withEmail: signedInEmail) != nil
    }

    /// An account can only be switched to if its saved session is still intact.
    func canRestore(_ profile: Profile) -> Bool {
        restorable.contains(profile.id)
    }

    func isActive(_ profile: Profile) -> Bool {
        profile.id == active?.id
    }

    func reading(for profile: Profile) -> Reading? {
        readings[profile.id]
    }

    // MARK: - The clock

    /// Starts the timer that keeps the window honest while nobody is touching it.
    ///
    /// Scheduled in `.common` mode rather than the default, or it would stop for
    /// as long as a menu is open or a window is being dragged — which is to say,
    /// during exactly the moments somebody is looking at it.
    private func startTicking() {
        let ticker = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        ticker.tolerance = Self.tick / 4
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func tick() {
        let previous = now
        now = Date()

        // Re-read, because figures on disk move while the window sits open: Claude
        // Code writes new ones as a session runs. Three file reads, which is cheap
        // enough to spend every half minute.
        reload()

        // A window turning over is the one moment worth spending a request on
        // without being asked. The number on screen has just become the spend of a
        // window that has ended, and there is no honest way to guess its
        // replacement — but there is a way to go and get it.
        if crossedAReset(between: previous, and: now) { fetch(because: .aWindowReset) }
    }

    private func crossedAReset(between previous: Date, and now: Date) -> Bool {
        readings.values.contains { reading in
            [reading.usage.fiveHour, reading.usage.sevenDay]
                .compactMap { $0?.resetsAt }
                .contains { $0 > previous && $0 <= now }
        }
    }

    // MARK: - Reading

    func reload() {
        // Claude Code writes fresh figures into the live settings file as it
        // goes. Folding them into the signed-in account's saved copy here is what
        // stops those figures being lost the moment it is switched away from.
        switcher.captureLiveUsage()

        roster = (try? switcher.roster()) ?? Roster()
        signedInEmail = switcher.liveSettings()?.email

        var restorable: Set<UUID> = []
        var readings: [UUID: Reading] = [:]

        for profile in roster.profiles {
            if switcher.hasSavedSession(profile) { restorable.insert(profile.id) }

            let live = isActive(profile)
            let reading = best(onDisk: switcher.usage(for: profile, isActive: live),
                               from: live ? .liveSettings : .savedSettings,
                               fetched: fetched[profile.id])
            if let reading { readings[profile.id] = reading }
        }

        self.restorable = restorable
        self.readings = readings

        // An account that has been removed keeps nothing behind it.
        let known = Set(roster.profiles.map(\.id))
        fetched = fetched.filter { known.contains($0.key) }
    }

    /// Which of the two sets of figures for an account to believe.
    ///
    /// Whichever was measured later, and the disk is allowed to win: the
    /// signed-in account's file is written by Claude Code as it works, so a
    /// fetch from five minutes ago is genuinely the older answer by then.
    ///
    /// "Later" means later by a second, not by any amount at all. A fetched
    /// reading is written to the saved file as well, as milliseconds since 1970
    /// and back, and a round trip through that costs a fraction of a fraction of
    /// a second — enough for a figure to come back from the disk looking newer
    /// than the fetch it came from, and be labelled as a memory of it.
    private func best(onDisk: Usage?, from source: UsageSource, fetched: Usage?) -> Reading? {
        guard let fetched else {
            return onDisk.map { Reading(usage: $0, source: source) }
        }
        if let onDisk, let written = onDisk.measuredAt, let asked = fetched.measuredAt,
           written > asked.addingTimeInterval(1) {
            return Reading(usage: onDisk, source: source)
        }
        return Reading(usage: fetched, source: .fetched)
    }

    // MARK: - Asking Anthropic

    private enum Prompting {
        case theRefreshButton
        case aWindowReset
    }

    /// The Refresh button: re-read the disk, then go and ask for the real numbers.
    func refresh() {
        guard !isWorking else { return }
        reload()

        // With nothing saved there is nobody to ask on behalf of, and a button
        // that does nothing at all reads as a button that is broken.
        guard !profiles.isEmpty else {
            failure = nil
            outcome = Outcome("Nothing to refresh yet.",
                              notes: ["Save an account and its figures appear here."])
            return
        }

        fetch(because: .theRefreshButton)
    }

    /// Fetches every account's current figures, including the ones not signed in.
    ///
    /// Sequential rather than all at once. There are two or three accounts, each
    /// request takes a moment, and doing them in turn keeps the keychain reads in
    /// a predictable order instead of racing each other for the same tool.
    private func fetch(because prompting: Prompting) {
        guard !isWorking, !profiles.isEmpty else { return }
        isWorking = true
        failure = nil

        // A fetch nobody asked for leaves whatever was on screen where it is.
        if prompting == .theRefreshButton {
            outcome = Outcome("Refreshing…",
                              notes: ["Asking Anthropic for each account's current figures."])
        }

        let targets = profiles.map { ($0, isActive($0)) }
        let switcher = switcher
        let moment = Date()

        Task {
            defer { isWorking = false }

            var measured: [UUID: Usage] = [:]
            var refused: [UUID: String] = [:]

            for (profile, live) in targets {
                do {
                    measured[profile.id] = try await switcher.fetchUsage(for: profile,
                                                                         isActive: live,
                                                                         now: moment)
                } catch {
                    refused[profile.id] = error.localizedDescription
                }
            }

            for (id, usage) in measured { fetched[id] = usage }
            now = Date()
            reload()

            // A fetch nobody asked for says nothing when it fails. The figures it
            // was going to replace are still on screen and still labelled with
            // when they were taken, and an error appearing by itself in a window
            // nobody touched is worse than the silence.
            if prompting == .theRefreshButton || refused.isEmpty {
                outcome = summary(measured: measured, refused: refused, prompting: prompting)
            }
        }
    }

    private func summary(measured: [UUID: Usage],
                         refused: [UUID: String],
                         prompting: Prompting) -> Outcome {
        var notes: [String] = []

        if !measured.isEmpty {
            let names = profiles.filter { measured[$0.id] != nil }.map(\.email)
            notes.append("\(Self.list(names)) measured just now, straight from Anthropic.")
        }

        for profile in profiles {
            if let reason = refused[profile.id] { notes.append("\(profile.email): \(reason)") }
        }

        // Said once, at the bottom, for whoever is looking at a figure that did
        // not move: what is on screen is still true of the moment it was taken.
        if !refused.isEmpty {
            notes.append("""
                         Accounts that could not be fetched keep the last figures Claude Code \
                         measured for them, which is what the line under each bar is dated by.
                         """)
        }

        // Not "could not reach Anthropic": reaching it and being turned away is a
        // different thing, and each account's own line above says which it was.
        if measured.isEmpty {
            return Outcome("Could not fetch the current figures.", notes: notes)
        }
        if prompting == .aWindowReset {
            return Outcome("A limit started over, so the figures were fetched again.", notes: notes)
        }
        return Outcome("Refreshed.", notes: notes)
    }

    /// "a@b.com and c@d.com", rather than a comma-separated list of two.
    private static func list(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Acting

    func addCurrentAccount() {
        perform { try $0.adoptCurrentAccount() }
    }

    func switchTo(_ profile: Profile) {
        perform { try $0.activate(profile.id) }
    }

    func switchToNext() {
        perform { try $0.switchToNext() }
    }

    func remove(_ profile: Profile) {
        perform { try $0.remove(profile.id) }
    }

    func tidy() {
        perform { try $0.tidy() }
    }

    func move(_ profile: Profile, by offset: Int) {
        perform {
            try $0.reorder(profile.id, by: offset)
            return nil
        }
    }

    func dismissMessage() {
        outcome = nil
        failure = nil
    }

    /// Runs one operation away from the main thread.
    ///
    /// Switching can stop to ask macOS for keychain permission, and that wait
    /// belongs anywhere except the thread drawing the window.
    private func perform(_ work: @escaping @Sendable (Switcher) throws -> Outcome?) {
        guard !isWorking else { return }
        isWorking = true
        outcome = nil
        failure = nil

        // macOS draws a keychain prompt in front of the app that asked for it, so
        // an app still in the background gets one nobody can see, and every button
        // stays disabled behind it. Coming forward first is what keeps a switch
        // waiting on a prompt from looking like a switch that has hung.
        NSApp.activate(ignoringOtherApps: true)

        let switcher = switcher
        Task {
            // The flag disables the whole interface, so it has to come back down
            // on every path out of here, cancellation included.
            defer {
                isWorking = false
                reload()
            }

            let result = await Task.detached { () -> Result<Outcome?, Error> in
                do { return .success(try work(switcher)) } catch { return .failure(error) }
            }.value

            switch result {
            case .success(let value): outcome = value
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
}
