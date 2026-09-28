import Foundation

public enum CodexSwitchError: LocalizedError, Equatable {
    case notSignedIn
    case alreadyActive(String)
    case unknownProfile
    case authUnwritable(URL)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Codex is not signed in on this Mac, so there is nothing to save."
        case .alreadyActive(let name):
            return "Codex is already signed in as \(name)."
        case .unknownProfile:
            return "That account is no longer on the list."
        case .authUnwritable(let url):
            return "Could not write \(url.path)."
        }
    }
}

/// Whether Codex is running right now, in any of its forms.
public enum CodexProcess {

    /// Matches the command line tool, the process the desktop app runs its agent
    /// in, and the desktop app itself, which are all called some case of "codex".
    public static func isRunning() -> Bool {
        guard let result = try? Command.run("/usr/bin/pgrep", ["-ix", "codex"]) else { return false }
        return result.succeeded
    }
}

/// Moves Codex's sign-in in and out of storage.
///
/// The same rules as `Switcher`, applied to a session that is one file rather
/// than two halves: get hold of the replacement first, save the sign-in being
/// displaced, and only then overwrite what is live. A failure at any step leaves
/// Codex signed into the account it was already signed into.
///
/// One thing matters more here than it does for Claude Code. ChatGPT refresh
/// tokens are single-use, and Codex renews its own every few days, writing the
/// new one into `auth.json` and invalidating the old. A saved copy taken before
/// that is a copy of a sign-in that no longer works. So the live file is saved
/// again at the moment it is switched away from, every time, rather than trusted
/// from whenever it was first added.
public final class CodexSwitcher: Sendable {

    private let vault: CodexVault
    private let authURL: URL
    private let api: CodexUsageEndpoint
    private let isCodexRunning: @Sendable () -> Bool

    public init(vault: CodexVault = CodexVault(),
                authURL: URL = CodexHome.authFile(),
                api: CodexUsageEndpoint = OpenAIUsage(),
                isCodexRunning: @escaping @Sendable () -> Bool = { CodexProcess.isRunning() }) {
        self.vault = vault
        self.authURL = authURL
        self.api = api
        self.isCodexRunning = isCodexRunning
    }

    private var fileManager: FileManager { .default }

    // MARK: - Reading

    public func roster() throws -> Roster {
        try vault.loadRoster()
    }

    /// Codex's live `auth.json`, if there is one and it parses.
    public func liveAuth() -> CodexAuth? {
        guard let data = fileManager.contents(atPath: authURL.path) else { return nil }
        return CodexAuth(data)
    }

    public func hasSavedSession(_ profile: Profile) -> Bool {
        vault.hasSession(for: profile.id)
    }

    // MARK: - Asking OpenAI

    /// An account's figures as they stand right now.
    ///
    /// The signed-in account is asked with the live file's token and is never
    /// renewed from here, for the reason `Switcher.fetchUsage` gives and with more
    /// force: a refresh token spent by Janus is one the running Codex can no
    /// longer use, and Codex would be signed out the next time it tried.
    ///
    /// A saved account is renewed when its token has run out, and what comes back
    /// is stored before it is used, because the renewal has already spent the
    /// only other copy.
    public func fetchUsage(for profile: Profile,
                           isActive: Bool,
                           now: Date = Date()) async throws -> Usage {
        let saved: CodexAuth
        if isActive {
            guard let live = liveAuth(), live.isSignedIn else { throw CodexAPIError.noCredentials }
            saved = live
        } else {
            saved = try vault.auth(for: profile.id)
        }
        guard saved.usesChatGPT else { throw CodexAPIError.apiKeyAccount }

        var auth = saved
        if !isActive, !auth.isFresh(at: now) {
            auth = try await renew(auth, for: profile.id, now: now)
        }

        var body: Data
        do {
            body = try await ask(with: auth)
        } catch CodexAPIError.signInAgain {
            guard !isActive else { throw CodexAPIError.signInRefused }
            // Renewed once already in this call and still refused: the sign-in
            // itself is gone. One attempt only.
            guard auth == saved else { throw CodexAPIError.signInAgain }
            auth = try await renew(auth, for: profile.id, now: now)
            body = try await ask(with: auth)
        }

        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CodexAPIError.malformedAnswer
        }
        let usage = Usage(codex: object, measuredAt: now)
        guard !usage.isEmpty else { throw CodexAPIError.noFigures }
        return usage
    }

    private func ask(with auth: CodexAuth) async throws -> Data {
        guard let token = auth.accessToken else { throw CodexAPIError.noCredentials }
        return try await api.usage(accessToken: token, accountID: auth.accountID)
    }

    private func renew(_ auth: CodexAuth, for id: UUID, now: Date) async throws -> CodexAuth {
        let renewed = try await api.renew(auth, now: now)
        try vault.store(renewed, for: id)
        return renewed
    }

    // MARK: - Writing

    /// Saves the signed-in account, adding it to the list if it is new.
    @discardableResult
    public func adoptCurrentAccount() throws -> Outcome {
        guard let live = liveAuth(), let name = live.name else { throw CodexSwitchError.notSignedIn }

        var roster = try vault.loadRoster()
        let existing = roster.profile(for: live)
        let profile = existing ?? Profile(email: name, accountID: live.accountID, plan: live.plan)

        try vault.store(live, for: profile.id)

        if existing == nil { roster.profiles.append(profile) }
        note(live, on: profile.id, in: &roster)
        stamp(&roster, active: profile.id)
        try vault.save(roster)

        return existing == nil
            ? Outcome("Now managing \(name) for Codex.")
            : Outcome("Saved the current Codex sign-in for \(name).")
    }

    /// Signs Codex into a saved account.
    @discardableResult
    public func activate(_ id: UUID) throws -> Outcome {
        var roster = try vault.loadRoster()
        guard let target = roster.profiles.first(where: { $0.id == id }) else {
            throw CodexSwitchError.unknownProfile
        }

        let live = liveAuth()
        if let live, roster.profile(for: live)?.id == target.id {
            throw CodexSwitchError.alreadyActive(target.email)
        }

        // Fetched before anything is disturbed. If this throws, on a missing entry
        // or a declined keychain prompt, nothing has changed yet.
        let replacement = try vault.auth(for: target.id)

        var notes: [String] = []
        switch try preserve(live, in: &roster) {
        case .saved(let name):
            notes.append("Saved \(name) first.")
        case .adopted(let name):
            notes.append("\(name) was not on the list, so it was added and saved.")
        case .nothingSignedIn:
            break
        }

        try install(replacement)

        stamp(&roster, active: target.id)
        try vault.save(roster)

        // Codex reads the file when it starts and writes it back whenever it
        // renews, so one still running is both deaf to the switch and able to
        // undo it, by writing the old account's renewed tokens over the new ones.
        if isCodexRunning() {
            notes.append("""
                         Codex is running. Quit it and start it again: until then it keeps \
                         using the previous account, and can put it back when it renews its sign-in.
                         """)
        } else {
            notes.append("Codex picks this up the next time it starts.")
        }
        return Outcome("Switched Codex to \(target.email).", notes: notes)
    }

    @discardableResult
    public func switchToNext() throws -> Outcome {
        let roster = try vault.loadRoster()
        let current = liveAuth().flatMap { roster.profile(for: $0) }
        guard let next = roster.successor(to: current) else { throw CodexSwitchError.unknownProfile }
        return try activate(next.id)
    }

    /// Drops an account and its saved sign-in. If it is the one signed in, Codex
    /// stays signed in; it just stops being something Janus can come back to.
    @discardableResult
    public func remove(_ id: UUID) throws -> Outcome {
        var roster = try vault.loadRoster()
        guard let profile = roster.profiles.first(where: { $0.id == id }) else {
            throw CodexSwitchError.unknownProfile
        }

        vault.discard(for: id)
        roster.profiles.removeAll { $0.id == id }
        if roster.activeID == id { roster.activeID = nil }
        try vault.save(roster)

        return Outcome("Removed \(profile.email).")
    }

    public func reorder(_ id: UUID, by offset: Int) throws {
        var roster = try vault.loadRoster()
        roster.move(id, by: offset)
        try vault.save(roster)
    }

    // MARK: - Steps

    enum Preserved: Equatable {
        case saved(String)
        case adopted(String)
        case nothingSignedIn
    }

    /// Files the live sign-in under whichever account it belongs to, adding the
    /// account if it is new, because the alternative is overwriting a sign-in that
    /// exists nowhere else.
    func preserve(_ live: CodexAuth?, in roster: inout Roster) throws -> Preserved {
        guard let live, let name = live.name else { return .nothingSignedIn }

        if let owner = roster.profile(for: live) {
            try vault.store(live, for: owner.id)
            note(live, on: owner.id, in: &roster)
            return .saved(name)
        }

        let adopted = Profile(email: name, accountID: live.accountID, plan: live.plan)
        try vault.store(live, for: adopted.id)
        roster.profiles.append(adopted)
        return .adopted(name)
    }

    /// Makes a saved sign-in the live one.
    ///
    /// Written to a file created owner-only from the start and then renamed into
    /// place, so the tokens are never readable by anyone else, even for the
    /// moment between writing and tightening, and Codex never sees half a file.
    func install(_ replacement: CodexAuth) throws {
        let parent = authURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".auth.json.janus-\(UUID().uuidString)")

        do {
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }

            let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw CodexSwitchError.authUnwritable(authURL) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: replacement.raw)
            try handle.close()

            guard rename(staging.path, authURL.path) == 0 else {
                throw CodexSwitchError.authUnwritable(authURL)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw CodexSwitchError.authUnwritable(authURL)
        }
    }

    /// Keeps what the list shows about an account in step with its latest
    /// sign-in: a plan that changed, or a workspace a roster written before it was
    /// recorded does not know yet.
    private func note(_ auth: CodexAuth, on id: UUID, in roster: inout Roster) {
        guard let index = roster.profiles.firstIndex(where: { $0.id == id }) else { return }
        if let plan = auth.plan { roster.profiles[index].plan = plan }
        if roster.profiles[index].accountID == nil { roster.profiles[index].accountID = auth.accountID }
    }

    private func stamp(_ roster: inout Roster, active id: UUID) {
        roster.activeID = id
        if let index = roster.profiles.firstIndex(where: { $0.id == id }) {
            roster.profiles[index].lastActiveAt = Date()
        }
    }
}
