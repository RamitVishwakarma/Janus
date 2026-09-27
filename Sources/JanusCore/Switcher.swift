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
    private let api: UsageEndpoint

    public init(vault: Vault = Vault(),
                session: Session = .current(),
                secrets: SecretStore = SystemKeychain(),
                api: UsageEndpoint = AnthropicUsage()) {
        self.vault = vault
        self.session = session
        self.secrets = secrets
        self.api = api
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

    /// Plan usage for an account as it can be had off the disk: the signed-in
    /// account's live figures, and for the rest whatever was last written into
    /// their saved copy — their sign-out, or the last time they were fetched.
    ///
    /// Costs nothing and cannot fail, which is why it is what the window draws
    /// first and `fetchUsage(for:isActive:now:)` only improves on.
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

    // MARK: - Asking Anthropic

    /// An account's figures as they stand right now, fetched rather than read.
    ///
    /// The only thing here that touches the network, and the only way a parked
    /// account's numbers can be anything but frozen: its saved settings file
    /// stopped moving when it was last signed out, and reading it again a week
    /// later gives the same answer it gave a week ago.
    ///
    /// The signed-in account is fetched without ever renewing its token, which is
    /// the one asymmetry worth stating plainly. Renewing spends the refresh token
    /// and issues another in its place, and a running Claude Code session holds
    /// the old one in memory; rotating it underneath that session is how a
    /// sign-in that was working stops working. Nothing is lost by the rule,
    /// because Claude Code keeps the live token fresh itself.
    public func fetchUsage(for profile: Profile,
                           isActive: Bool,
                           now: Date = Date()) async throws -> Usage {
        let saved = try credentials(for: profile, isActive: isActive)
        var credentials = saved

        if !isActive, !credentials.isFresh(at: now) {
            credentials = try await renew(credentials, for: profile.id, now: now)
        }

        var body: Data
        do {
            body = try await api.usage(accessToken: credentials.accessToken)
        } catch UsageAPIError.signInAgain {
            // The signed-in account is never renewed from here, so a refusal is
            // as far as it goes — and it needs saying differently, because the
            // account it happened to is the one already signed in.
            guard !isActive else { throw UsageAPIError.signInRefused }

            // A token already renewed once in this call and refused anyway means
            // the sign-in itself is gone, not merely stale. One attempt only.
            guard credentials == saved else { throw UsageAPIError.signInAgain }

            // Rejected while still in date, which happens when a sign-in was
            // revoked or the clock disagrees. Worth one renewal before giving up,
            // because the refresh token may well outlive whatever went wrong.
            credentials = try await renew(credentials, for: profile.id, now: now)
            body = try await api.usage(accessToken: credentials.accessToken)
        }

        guard let limits = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw UsageAPIError.malformedAnswer
        }

        // An answer with no limits in it is not a reading. Claude Code's own
        // client returns an empty object for accounts it cannot measure, and
        // taking that at face value would blank a perfectly good saved figure —
        // and then write the blank over it, which is the one mistake here that
        // cannot be undone by asking again.
        let usage = Usage(limits: limits, measuredAt: now)
        guard !usage.isEmpty else { throw UsageAPIError.noFigures }

        // Kept only for saved accounts. The live settings file belongs to Claude
        // Code, which is writing its own figures into it as it goes, and a second
        // writer is a good way to lose whichever set of numbers lands first.
        if !isActive { vault.rememberUsage(limits, for: profile.id, at: now) }

        return usage
    }

    private func credentials(for profile: Profile, isActive: Bool) throws -> Credentials {
        guard isActive else { return try vault.credentials(for: profile.id) }
        guard let raw = try? secrets.read(session.credentials), let parsed = Credentials(raw) else {
            throw UsageAPIError.noCredentials
        }
        return parsed
    }

    private func renew(_ credentials: Credentials, for id: UUID, now: Date) async throws -> Credentials {
        let renewed = try await api.renew(credentials, now: now)

        // Stored before it is used for anything. The renewal has already spent
        // the token that was there, so what came back is now the only way into
        // this account that exists; dropping it because the request after this
        // one failed would leave the account needing a fresh sign-in.
        try vault.replaceCredentials(renewed, for: id)
        return renewed
    }

    // MARK: - Writing

    /// Copies the signed-in account's settings into its saved slot, so the
    /// figures Janus shows for it keep up with what Claude Code has measured.
    ///
    /// One file copy and no keychain access and no network, which is what makes
    /// it cheap enough to do every time the window redraws itself. It is also the
    /// only account whose figures move on their own: the rest are files Claude
    /// Code is not writing to, and only `fetchUsage(for:isActive:now:)` can move
    /// those.
    ///
    /// - Returns: the account brought up to date, if there was one.
    @discardableResult
    public func captureLiveUsage() -> UUID? {
        guard let settings = liveSettings(),
              let email = settings.email,
              let roster = try? vault.loadRoster(),
              let owner = roster.profile(withEmail: email),
              vault.hasSession(for: owner.id)
        else { return nil }

        try? vault.refreshStoredSettings(settings.raw, for: owner.id)
        return owner.id
    }

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

        // Fetch the replacement before disturbing anything. If this throws, say
        // on a missing entry or a declined keychain prompt, nothing has changed yet.
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

        // Written back now that the live session is safely in place. Entries an
        // older build left behind are partitioned to a code signature that no
        // longer exists, and every switch would otherwise stop to ask for the
        // login password; storing them again mends that for good. Nothing is at
        // risk if it fails, because the tokens are already live.
        try? vault.store(replacement, for: target.id)

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
    /// session keeps working. It just stops being something Janus can come
    /// back to.
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
    ///
    /// The only reason to carry on without saving is that there is genuinely
    /// nothing signed in. A keychain that refuses to hand the tokens over is a
    /// different thing entirely, and has to stop the switch: carrying on would
    /// overwrite a live session whose only copy is the one being refused, and
    /// leave the account it belonged to needing a fresh sign-in.
    func preserveCurrentSession(in roster: inout Roster) throws -> Preserved {
        guard let settings = liveSettings(), let email = settings.email else {
            return .nothingSignedIn
        }

        let credentials: Data
        do {
            credentials = try secrets.read(session.credentials)
        } catch SecretError.notFound {
            // Settings name an account but the tokens are gone, so there is no
            // session here to lose.
            return .nothingSignedIn
        }

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
    /// Credentials go first because that is the step most likely to be refused,
    /// since it is the one macOS may put a prompt in front of. If the settings file
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
