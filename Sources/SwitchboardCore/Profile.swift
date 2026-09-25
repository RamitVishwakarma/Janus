import Foundation

/// One account Switchboard looks after.
///
/// Identified by a UUID rather than a position, so reordering the rotation is
/// only ever a change to this file — nothing stored under the account has to move
/// with it.
public struct Profile: Identifiable, Codable, Hashable {
    public let id: UUID
    public var email: String
    public var addedAt: Date
    public var lastActiveAt: Date?

    public init(id: UUID = UUID(),
                email: String,
                addedAt: Date = Date(),
                lastActiveAt: Date? = nil) {
        self.id = id
        self.email = email
        self.addedAt = addedAt
        self.lastActiveAt = lastActiveAt
    }

    /// "ramit" out of "ramit@example.com" — enough to tell accounts apart in a
    /// menu bar, where a full address would not fit.
    public var shortName: String {
        let name = email.split(separator: "@").first.map(String.init) ?? email
        return name.isEmpty ? email : name
    }
}

/// Everything Switchboard knows, in the order the rotation visits it.
public struct Roster: Codable, Equatable {

    /// Bumped only if the layout on disk ever changes shape.
    public static let currentSchema = 1

    public var schema: Int
    public var profiles: [Profile]
    public var activeID: UUID?

    public init(schema: Int = Roster.currentSchema,
                profiles: [Profile] = [],
                activeID: UUID? = nil) {
        self.schema = schema
        self.profiles = profiles
        self.activeID = activeID
    }

    public var active: Profile? {
        guard let activeID else { return nil }
        return profiles.first { $0.id == activeID }
    }

    /// The account a plain "switch" moves to: the next one round the rotation.
    public var next: Profile? { successor(to: active) }

    /// The account after this one, wrapping at the end.
    ///
    /// Takes the current account as an argument rather than reading `activeID`,
    /// because the account signed in right now is not always the one this file
    /// last recorded — somebody can sign in without going through the app.
    public func successor(to current: Profile?) -> Profile? {
        guard let current, profiles.count > 1,
              let position = profiles.firstIndex(where: { $0.id == current.id })
        else { return profiles.first { $0.id != current?.id } }
        return profiles[(position + 1) % profiles.count]
    }

    /// Whoever is signed in, preferring the evidence over the record.
    public func active(signedInAs email: String?) -> Profile? {
        if let email, let match = profile(withEmail: email) { return match }
        return active
    }

    public func profile(withEmail email: String) -> Profile? {
        profiles.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    public mutating func move(_ id: UUID, by offset: Int) {
        guard let from = profiles.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard profiles.indices.contains(to) else { return }
        profiles.swapAt(from, to)
    }
}
