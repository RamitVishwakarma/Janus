import Foundation

/// How much of a plan's limits an account has spent.
///
/// Comes from one of two places, which `UsageSource` names: Claude Code's own
/// settings file, which costs nothing to read but only ever holds what the last
/// session measured, or Anthropic's usage endpoint, which is current but needs
/// the network and the account's token. `measuredAt` is what makes the
/// difference sayable out loud rather than left for someone to guess.
public struct Usage: Equatable {

    /// One rolling limit: how much of it is gone, and when it starts over.
    public struct Window: Equatable {
        public let percentUsed: Int
        public let resetsAt: Date?

        public init(percentUsed: Int, resetsAt: Date?) {
            self.percentUsed = percentUsed
            self.resetsAt = resetsAt
        }

        /// True once the reset moment has gone by, which makes `percentUsed` the
        /// spend of a window that has already ended.
        ///
        /// Claude Code measures only while a session is running, so the figure it
        /// last wrote sits here unchanged across the reset. Reading it as the
        /// current one is how a limit that has actually started over comes to look
        /// like a limit that is still full.
        public func hasReset(by now: Date = Date()) -> Bool {
            guard let resetsAt else { return false }
            return resetsAt <= now
        }
    }

    /// Which products the weekly spend went to, e.g. ("Claude Code", 98).
    public struct Slice: Equatable {
        public let label: String
        public let percent: Int

        public init(label: String, percent: Int) {
            self.label = label
            self.percent = percent
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var breakdown: [Slice] = []
    public var measuredAt: Date?

    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil }

    /// The limits that have started over since these figures were taken, named the
    /// way they are labelled on screen.
    ///
    /// Named rather than counted because the answer is only useful with the remedy
    /// attached, and the remedy is worth saying out loud: nothing moves here until
    /// Claude Code runs again.
    public func resetWindows(by now: Date = Date()) -> [String] {
        var names: [String] = []
        if fiveHour?.hasReset(by: now) == true { names.append("5-hour") }
        if sevenDay?.hasReset(by: now) == true { names.append("7-day") }
        return names
    }

    public init(fiveHour: Window? = nil,
                sevenDay: Window? = nil,
                breakdown: [Slice] = [],
                measuredAt: Date? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.breakdown = breakdown
        self.measuredAt = measuredAt
    }

    /// Builds a reading from the `cachedUsageUtilization` object.
    public init?(_ cached: [String: Any]) {
        if let milliseconds = cached["fetchedAtMs"] as? Double {
            measuredAt = Date(timeIntervalSince1970: milliseconds / 1000)
        }

        guard let limits = cached["utilization"] as? [String: Any] else {
            if measuredAt == nil { return nil }
            return
        }

        read(limits)
    }

    /// Builds a reading from the limits object on its own, which is the shape the
    /// usage endpoint answers in and the shape Claude Code files under
    /// `utilization` when it writes the same answer to disk.
    public init(limits: [String: Any], measuredAt: Date) {
        self.measuredAt = measuredAt
        read(limits)
    }

    private mutating func read(_ limits: [String: Any]) {
        fiveHour = Usage.window(limits["five_hour"])
        sevenDay = Usage.window(limits["seven_day"])

        if let breakdown = limits["seven_day_breakdown"] as? [String: Any],
           let rows = breakdown["rows"] as? [[String: Any]] {
            self.breakdown = rows.compactMap { row in
                guard let label = row["display_name"] as? String,
                      let percent = Usage.percent(row["percent"]), percent > 0
                else { return nil }
                return Slice(label: label, percent: percent)
            }
        }
    }

    private static func window(_ value: Any?) -> Window? {
        guard let object = value as? [String: Any],
              let percent = percent(object["utilization"])
        else { return nil }
        return Window(percentUsed: percent, resetsAt: timestamp(object["resets_at"] as? String))
    }

    /// A percentage as a whole number, whichever way it arrived.
    ///
    /// The settings file holds these as integers and the endpoint answers with
    /// decimals for the same fields, so reading only one of the two would leave
    /// every fetched figure missing rather than merely imprecise.
    static func percent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return Int(number.doubleValue.rounded())
    }

    static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = reader.date(from: text) { return parsed }
        reader.formatOptions = [.withInternetDateTime]
        return reader.date(from: text)
    }
}

/// Where a reading came from, which is the whole of what decides how much it can
/// be trusted to be current.
public enum UsageSource: Equatable, Sendable {

    /// Claude Code's live settings file: as current as the last session made it.
    case liveSettings

    /// The copy saved when the account was last signed out. Frozen ever since.
    case savedSettings

    /// Asked of Anthropic just now, for an account that need not be signed in.
    case fetched
}

/// Durations phrased the way someone deciding whether to keep working would want
/// them: "in 3h 20m", not a timestamp they have to subtract from the clock.
public enum Elapsed {

    public static func until(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds > 0 { return "resets in " + spell(seconds) }

        // Past the reset the phrase has to keep moving, or a limit that turned
        // over yesterday reads the same as one turning over this second, and
        // "resetting now" that never stops is indistinguishable from a stuck app.
        guard seconds < -60 else { return "resetting now" }
        return "last reset " + spell(-seconds) + " ago"
    }

    public static func since(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "just now" }
        return spell(seconds) + " ago"
    }

    private static func spell(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(max(minutes, 1))m" }

        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }

        let days = hours / 24
        let remainder = hours % 24
        return remainder == 0 ? "\(days)d" : "\(days)d \(remainder)h"
    }
}
