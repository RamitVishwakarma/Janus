import AppKit
import Foundation
import SwiftUI
import JanusCore

/// Everything the interface knows about Codex accounts, and the only place it
/// asks for any of them to change.
///
/// The same shape as `AccountsModel`, minus the parts that have nothing to read:
/// Codex does not write its limits anywhere Janus can pick them up for free, so
/// figures here only ever come from Refresh, and are kept for as long as the app
/// is open.
@MainActor
final class CodexModel: ObservableObject {

    @Published private(set) var roster = Roster()
    @Published private(set) var readings: [UUID: Usage] = [:]
    @Published private(set) var restorable: Set<UUID> = []
    @Published private(set) var signedInName: String?
    @Published private(set) var activeID: UUID?
    @Published private(set) var isWorking = false
    @Published private(set) var outcome: Outcome?
    @Published private(set) var failure: String?
    @Published private(set) var now = Date()

    private let switcher: CodexSwitcher
    private var ticker: Timer?

    init(switcher: CodexSwitcher = CodexSwitcher()) {
        self.switcher = switcher
        reload()
        startTicking()
    }

    deinit { ticker?.invalidate() }

    // MARK: - Derived state

    var profiles: [Profile] { roster.profiles }

    /// The account Codex is signed into, going by the live file alone. A roster
    /// that says otherwise is out of date: somebody signed in without the app.
    var active: Profile? {
        guard let activeID else { return nil }
        return roster.profiles.first { $0.id == activeID }
    }

    var next: Profile? { roster.successor(to: active) }

    var currentAccountIsManaged: Bool { activeID != nil }

    func canRestore(_ profile: Profile) -> Bool { restorable.contains(profile.id) }

    func isActive(_ profile: Profile) -> Bool { profile.id == activeID }

    func reading(for profile: Profile) -> Reading? {
        readings[profile.id].map { Reading(usage: $0, source: .fetched) }
    }

    // MARK: - The clock

    /// Keeps countdowns moving and notices sign-ins made outside the app, on the
    /// same half-minute tick and in the same run loop mode as the Claude side.
    private func startTicking() {
        let ticker = Timer(timeInterval: AccountsModel.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.reload()
            }
        }
        ticker.tolerance = AccountsModel.tick / 4
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    // MARK: - Reading

    /// One file read and a keychain existence check per account. Never asks for a
    /// secret, so it can never raise a prompt.
    func reload() {
        roster = (try? switcher.roster()) ?? Roster()

        let live = switcher.liveAuth()
        signedInName = live?.name
        activeID = live.flatMap { roster.profile(for: $0) }?.id

        restorable = Set(roster.profiles.filter(switcher.hasSavedSession).map(\.id))

        let known = Set(roster.profiles.map(\.id))
        readings = readings.filter { known.contains($0.key) }
    }

    // MARK: - Asking OpenAI

    func refresh() {
        guard !isWorking else { return }
        reload()

        guard !profiles.isEmpty else {
            failure = nil
            outcome = Outcome("Nothing to refresh yet.",
                              notes: ["Save a Codex account and its figures appear here."])
            return
        }

        isWorking = true
        failure = nil
        outcome = Outcome("Refreshing…", notes: ["Asking OpenAI for each account's current figures."])

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

            for (id, usage) in measured { readings[id] = usage }
            now = Date()
            reload()
            outcome = summary(measured: measured, refused: refused)
        }
    }

    private func summary(measured: [UUID: Usage], refused: [UUID: String]) -> Outcome {
        var notes: [String] = []

        let names = profiles.filter { measured[$0.id] != nil }.map(\.email)
        if !names.isEmpty {
            notes.append("\(names.joined(separator: ", ")) measured just now, straight from OpenAI.")
        }
        for profile in profiles {
            if let reason = refused[profile.id] { notes.append("\(profile.email): \(reason)") }
        }

        return measured.isEmpty
            ? Outcome("Could not fetch the current figures.", notes: notes)
            : Outcome("Refreshed.", notes: notes)
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

    /// Runs one operation away from the main thread, for the reason
    /// `AccountsModel.perform` gives: a switch can stop and wait on the keychain.
    private func perform(_ work: @escaping @Sendable (CodexSwitcher) throws -> Outcome?) {
        guard !isWorking else { return }
        isWorking = true
        outcome = nil
        failure = nil

        NSApp.activate(ignoringOtherApps: true)

        let switcher = switcher
        Task {
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
