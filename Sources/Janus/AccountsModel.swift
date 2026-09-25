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

        let switcher = switcher
        Task {
            let result = await Task.detached { () -> Result<Outcome?, Error> in
                do { return .success(try work(switcher)) } catch { return .failure(error) }
            }.value

            switch result {
            case .success(let value): outcome = value
            case .failure(let error): failure = error.localizedDescription
            }

            isWorking = false
            reload()
        }
    }
}
