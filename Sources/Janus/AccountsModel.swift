import AppKit
import Foundation
import SwiftUI
import JanusCore

/// Everything the interface knows about accounts, and the only place it asks for
/// anything to change.
///
/// Reading is cheap and happens often: it touches files and asks the keychain
/// whether entries exist, but never asks for a secret, so refreshing the window
/// can never raise a permission prompt. Only an actual switch does that.
@MainActor
final class AccountsModel: ObservableObject {

    @Published private(set) var roster = Roster()
    @Published private(set) var usage: [UUID: Usage] = [:]
    @Published private(set) var restorable: Set<UUID> = []
    @Published private(set) var signedInEmail: String?
    @Published private(set) var isWorking = false
    @Published private(set) var outcome: Outcome?
    @Published private(set) var failure: String?

    private let switcher: Switcher

    init(switcher: Switcher = Switcher()) {
        self.switcher = switcher
        reload()
    }

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

    // MARK: - Reading

    func reload() {
        // Claude Code writes fresh figures into the live settings file as it
        // goes. Folding them into the signed-in account's saved copy here is what
        // stops those figures being lost the moment it is switched away from.
        switcher.captureLiveUsage()

        roster = (try? switcher.roster()) ?? Roster()
        signedInEmail = switcher.liveSettings()?.email

        var restorable: Set<UUID> = []
        var readings: [UUID: Usage] = [:]

        for profile in roster.profiles {
            if switcher.hasSavedSession(profile) { restorable.insert(profile.id) }
            if let reading = switcher.usage(for: profile, isActive: isActive(profile)) {
                readings[profile.id] = reading
            }
        }

        self.restorable = restorable
        self.usage = readings
    }

    /// The Refresh button.
    ///
    /// Says what it did, because a refresh that changes nothing on screen and a
    /// refresh that did nothing look identical otherwise — and only one account's
    /// figures can ever move, which is worth saying out loud rather than leaving
    /// people to press the button again.
    func refresh() {
        guard !isWorking else { return }
        reload()

        let others = profiles.filter { !isActive($0) }
        var notes: [String] = []

        if let active, let reading = usage[active.id] {
            let reset = reading.resetWindows()
            if reset.isEmpty {
                notes.append("\(active.email) is up to date.")
            } else {
                // The one case where pressing Refresh again will never help:
                // Claude Code measures while a session runs, and no session has
                // run since the window turned over, so there is nothing to read.
                notes.append("""
                             The \(Self.list(reset)) \(reset.count == 1 ? "limit has" : "limits have") \
                             started over since Claude Code last measured \(active.email). Start a \
                             Claude Code session and the new figure appears here.
                             """)
            }
        } else if let active {
            notes.append("Claude Code has not recorded any usage for \(active.email) yet.")
        }
        if !others.isEmpty {
            notes.append("""
                         The other \(others.count == 1 ? "account keeps the figures" : "accounts keep the figures") \
                         from when \(others.count == 1 ? "it was" : "they were") last signed in. Claude Code only \
                         measures the account signed in now, so Janus has nothing newer to read.
                         """)
        }

        failure = nil
        outcome = Outcome("Refreshed.", notes: notes)
    }

    /// "5-hour and 7-day", rather than a comma-separated list of two.
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
