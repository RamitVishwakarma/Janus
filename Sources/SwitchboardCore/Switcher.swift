import Foundation

/// What happened, in words the interface can show without rephrasing.
public struct Outcome: Equatable {
    public let headline: String
    public var notes: [String]

    public init(_ headline: String, notes: [String] = []) {
        self.headline = headline
        self.notes = notes
    }
}

public enum SwitchError: LocalizedError, Equatable {
    case notSignedIn
    case alreadyActive(String)
    case unknownProfile
    case settingsUnwritable(URL)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Claude Code account is signed in on this Mac, so there is nothing to save."
        case .alreadyActive(let email):
            return "Already signed in as \(email)."
        case .unknownProfile:
            return "That account is no longer on the list."
        case .settingsUnwritable(let url):
            return "Could not write \(url.path)."
        }
    }
}

/// Moves the signed-in session in and out of storage.
///
/// Every operation here follows the same order: get hold of the replacement
/// session first, save the one being displaced, and only then overwrite what is
/// live. A failure at any step leaves the Mac signed into the account it was
/// already signed into.
public final class Switcher: Sendable {

    private let vault: Vault
    private let session: Session
    private let secrets: SecretStore

    public init(vault: Vault = Vault(),
                session: Session = .current(),
                secrets: SecretStore = SystemKeychain()) {
        self.vault = vault
        self.session = session
        self.secrets = secrets
    }

    private var fileManager: FileManager { .default }

    // MARK: - Reading

    public func roster() throws -> Roster {
        try vault.loadRoster()
    }

    /// The settings file of whoever is signed in right now.
    public func liveSettings() -> SessionSettings? {
        guard let data = fileManager.contents(atPath: session.settingsURL.path) else { return nil }
        return SessionSettings(raw: data)
    }

    public func hasSavedSession(_ profile: Profile) -> Bool {
        vault.hasSession(for: profile.id)
    }

    /// Plan usage for an account: live figures for the signed-in one, and the
    /// figures frozen at its last sign-out for the rest.
    public func usage(for profile: Profile, isActive: Bool) -> Usage? {
        if isActive { return liveSettings()?.usage }
        guard let stored = vault.storedSettings(for: profile.id) else { return nil }
        let settings = SessionSettings(raw: stored)
        // A slot can hold a session that was saved under a since-changed email.
        // The payload is the authority on whose numbers these are.
        guard settings.email == nil || settings.email?.caseInsensitiveCompare(profile.email) == .orderedSame
        else { return nil }
        return settings.usage
    }

    // MARK: - Writing

    /// Saves the signed-in account, adding it to the roster if it is new.
    @discardableResult
    public func adoptCurrentAccount() throws -> Outcome {
        guard let settings = liveSettings(), let email = settings.email else {
            throw SwitchError.notSignedIn
        }
        let credentials = try secrets.read(session.credentials)
        let live = StoredSession(credentials: credentials, settings: settings.raw)

        var roster = try vault.loadRoster()
        let existing = roster.profile(withEmail: email)
        let profile = existing ?? Profile(email: email)

        try vault.store(live, for: profile.id)

        if existing == nil { roster.profiles.append(profile) }
        stamp(&roster, active: profile.id)
        try vault.save(roster)

        return existing == nil
            ? Outcome("Now managing \(email).")
            : Outcome("Saved the current session for \(email).")
    }

    /// Signs the Mac into a saved account.
    @discardableResult
    public func activate(_ id: UUID) throws -> Outcome {
        var roster = try vault.loadRoster()
        guard let target = roster.profiles.first(where: { $0.id == id }) else {
            throw SwitchError.unknownProfile
        }
        // Measured against the live settings file rather than the roster's own
        // record of what is active: signing in outside the app makes that record
        // stale, and switching back to the account it names is then a perfectly
        // reasonable thing to ask for.
        if let live = liveSettings()?.email,
           live.caseInsensitiveCompare(target.email) == .orderedSame {
            throw SwitchError.alreadyActive(target.email)
        }

        // Fetch the replacement before disturbing anything. If this throws — a
        // missing entry, a declined keychain prompt — nothing has changed yet.
        let replacement = try vault.session(for: target.id)

        var notes: [String] = []
        switch try preserveCurrentSession(in: &roster) {
        case .saved(let email):
            notes.append("Saved \(email) first.")
        case .adopted(let email):
            notes.append("\(email) was not on the list, so it was added and saved.")
        case .nothingSignedIn:
            break
        }

        try install(replacement)

        stamp(&roster, active: target.id)
        try vault.save(roster)

        notes.append("Restart any running Claude Code session to pick this up.")
        return Outcome("Switched to \(target.email).", notes: notes)
    }

    @discardableResult
    public func switchToNext() throws -> Outcome {
        let roster = try vault.loadRoster()
        let current = roster.active(signedInAs: liveSettings()?.email)
        guard let next = roster.successor(to: current) else { throw SwitchError.unknownProfile }
        return try activate(next.id)
    }

    /// Drops an account and everything saved under it.
    ///
    /// Only the saved copy goes. If it is the account currently signed in, that
    /// session keeps working — it simply stops being something Switchboard can
    /// come back to.
    @discardableResult
    public func remove(_ id: UUID) throws -> Outcome {
        var roster = try vault.loadRoster()
        guard let profile = roster.profiles.first(where: { $0.id == id }) else {
            throw SwitchError.unknownProfile
        }

        vault.discardSession(for: id)
        roster.profiles.removeAll { $0.id == id }
        if roster.activeID == id { roster.activeID = nil }
        try vault.save(roster)

        return Outcome("Removed \(profile.email).")
    }

    /// Moves an account one place along the rotation.
    public func reorder(_ id: UUID, by offset: Int) throws {
        var roster = try vault.loadRoster()
        roster.move(id, by: offset)
        try vault.save(roster)
    }

    /// Deletes saved settings files whose account is no longer on the roster.
    @discardableResult
    public func tidy() throws -> Outcome {
        let stranded = vault.strandedSettingsFiles(roster: try vault.loadRoster())
        guard !stranded.isEmpty else { return Outcome("Nothing left over to clean up.") }
        stranded.forEach { try? fileManager.removeItem(at: $0) }
        return Outcome("Removed \(stranded.count) leftover \(stranded.count == 1 ? "file" : "files").")
    }

    // MARK: - Steps

    enum Preserved: Equatable {
        case saved(String)
        case adopted(String)
        case nothingSignedIn
    }

    /// Files the signed-in session under whichever account it belongs to.
    ///
    /// An account that is signed in but unmanaged gets added rather than skipped:
    /// the alternative is overwriting credentials that exist nowhere else.
    func preserveCurrentSession(in roster: inout Roster) throws -> Preserved {
        guard let settings = liveSettings(),
              let email = settings.email,
              let credentials = try? secrets.read(session.credentials)
        else { return .nothingSignedIn }

        let live = StoredSession(credentials: credentials, settings: settings.raw)

        if let owner = roster.profile(withEmail: email) {
            try vault.store(live, for: owner.id)
            return .saved(email)
        }

        let adopted = Profile(email: email)
        try vault.store(live, for: adopted.id)
        roster.profiles.append(adopted)
        return .adopted(email)
    }

    /// Makes a stored session the live one.
    ///
    /// Credentials go first because that is the step most likely to be refused —
    /// it is the one macOS may put a prompt in front of. If the settings file
    /// then fails to write, the credentials are put back, because a session whose
    /// two halves belong to different accounts is worse than no change at all.
    func install(_ replacement: StoredSession) throws {
        let previousCredentials = try? secrets.read(session.credentials)
        try secrets.write(replacement.credentials, to: session.credentials)

        do {
            try createSettingsDirectoryIfNeeded()
            try replacement.settings.write(to: session.settingsURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: session.settingsURL.path)
        } catch {
            if let previousCredentials {
                try? secrets.write(previousCredentials, to: session.credentials)
            }
            throw SwitchError.settingsUnwritable(session.settingsURL)
        }
    }

    private func createSettingsDirectoryIfNeeded() throws {
        let parent = session.settingsURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: parent.path) else { return }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func stamp(_ roster: inout Roster, active id: UUID) {
        roster.activeID = id
        if let index = roster.profiles.firstIndex(where: { $0.id == id }) {
            roster.profiles[index].lastActiveAt = Date()
        }
    }
}
