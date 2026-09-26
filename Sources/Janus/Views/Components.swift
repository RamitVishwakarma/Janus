import SwiftUI
import JanusCore

/// A row of coloured advice with one thing to do about it.
struct Notice: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(12)
        .background(tint.opacity(0.09))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// What just happened, shown where the button that caused it was.
struct Message: View {
    let outcome: Outcome?
    let failure: String?

    var body: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let outcome {
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.headline).font(.callout)
                ForEach(outcome.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One limit, drawn as a bar. The colour is the warning, not decoration.
///
/// A window whose reset has gone by is drawn empty with a dash in place of the
/// percentage. The last figure is not the current one and there is no honest way
/// to guess what replaced it, so the bar says nothing rather than saying the old
/// number again.
struct LimitBar: View {
    let caption: String
    let window: Usage.Window

    private var hasReset: Bool { window.hasReset() }

    private var tint: Color {
        switch window.percentUsed {
        case ..<50: return .green
        case ..<80: return .yellow
        default:    return .orange
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    if !hasReset {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(2, geometry.size.width
                                                 * Double(min(window.percentUsed, 100)) / 100))
                    }
                }
            }
            .frame(width: 88, height: 5)

            Text(hasReset ? "—" : "\(window.percentUsed)%")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(hasReset ? .tertiary : .secondary)
                .frame(width: 34, alignment: .leading)

            if let resets = Elapsed.until(window.resetsAt) {
                Text(resets)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Both limits plus a line saying how current the figures are, which matters
/// because a saved account's numbers stopped moving when it was last signed in.
struct UsagePanel: View {
    let usage: Usage
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let window = usage.fiveHour { LimitBar(caption: "5-hour", window: window) }
            if let window = usage.sevenDay { LimitBar(caption: "7-day", window: window) }

            HStack(spacing: 5) {
                Text(freshness)
                if !usage.breakdown.isEmpty {
                    Text("·")
                    Text(usage.breakdown.map { "\($0.label) \($0.percent)%" }
                        .joined(separator: ", "))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let advice {
                Text(advice)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var freshness: String {
        if isLive {
            // "current" stops being true the moment a window turns over: the file
            // is still the latest one Claude Code wrote, and that is now old news.
            guard !usage.resetWindows().isEmpty,
                  let measured = Elapsed.since(usage.measuredAt)
            else { return "current" }
            return "measured \(measured)"
        }
        if let measured = Elapsed.since(usage.measuredAt) {
            return "measured \(measured), when last signed in"
        }
        return "from the last saved session"
    }

    /// What to do about a figure that has stopped moving.
    ///
    /// Only offered for the signed-in account, because it is the only one a
    /// session can be started for without switching first — and a saved account's
    /// line already says its numbers are frozen at its last sign-in.
    private var advice: String? {
        guard isLive, !usage.resetWindows().isEmpty else { return nil }
        return "Start a Claude Code session to measure the new window."
    }
}
