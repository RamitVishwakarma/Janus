import AppKit
import SwiftUI
import JanusCore

/// The menu bar panel: every account's limits at a glance, a switch beside each,
/// and the few things worth doing without opening the window.
///
/// A panel rather than a menu, because a menu can only hold lines of text. The
/// question someone clicks the menu bar to answer is which account has room left,
/// and that is a pair of bars per account, not a sentence.
struct MenuBarPanel: View {

    @ObservedObject var accounts: AccountsModel
    @ObservedObject var codex: CodexModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            claudeSection
            Divider().padding(.horizontal, 14)
            codexSection
            Divider().padding(.horizontal, 14)
            commands
        }
        .padding(.vertical, 6)
        .frame(width: 380)
        // The models tick on their own every half minute. Opening the panel is a
        // moment someone is about to read the figures, so it re-reads the disk
        // too rather than showing whatever the last tick found.
        .onAppear {
            accounts.reload()
            codex.reload()
        }
    }

    // MARK: - Sections

    private var claudeSection: some View {
        PanelSection(title: "Claude", isWorking: accounts.isWorking, failure: accounts.failure) {
            if let email = accounts.signedInEmail, !accounts.currentAccountIsManaged {
                UnsavedRow(name: email, isBusy: accounts.isWorking) { accounts.addCurrentAccount() }
            } else if accounts.profiles.isEmpty {
                SignedOutRow()
            }

            ForEach(accounts.profiles) { profile in
                PanelAccountRow(
                    profile: profile,
                    isActive: accounts.isActive(profile),
                    isBusy: accounts.isWorking,
                    canRestore: accounts.canRestore(profile),
                    reading: accounts.reading(for: profile),
                    now: accounts.now,
                    provider: "Anthropic",
                    incomplete: "Saved session incomplete",
                    // ⌘S has always meant "the next Claude Code account round",
                    // from the menu bar, and keeps meaning it here.
                    shortcut: profile.id == accounts.next?.id ? KeyboardShortcut("s") : nil,
                    onSwitch: { accounts.switchTo(profile) }
                )
            }
        }
    }

    private var codexSection: some View {
        PanelSection(title: "Codex", isWorking: codex.isWorking, failure: codex.failure) {
            if let name = codex.signedInName, !codex.currentAccountIsManaged {
                UnsavedRow(name: name, isBusy: codex.isWorking) { codex.addCurrentAccount() }
            } else if codex.profiles.isEmpty {
                SignedOutRow()
            }

            ForEach(codex.profiles) { profile in
                PanelAccountRow(
                    profile: profile,
                    detail: profile.plan.map { $0.capitalized },
                    isActive: codex.isActive(profile),
                    isBusy: codex.isWorking,
                    canRestore: codex.canRestore(profile),
                    reading: codex.reading(for: profile),
                    now: codex.now,
                    provider: "OpenAI",
                    incomplete: "Saved sign-in missing",
                    onSwitch: { codex.switchTo(profile) }
                )
            }
        }
    }

    private var commands: some View {
        VStack(spacing: 0) {
            PanelCommand(title: "Refresh usage", key: "r",
                         isEnabled: !accounts.isWorking && !codex.isWorking) {
                accounts.refresh()
                if !codex.profiles.isEmpty { codex.refresh() }
            }
            PanelCommand(title: "Open Janus…", key: "o") { reveal() }
            PanelCommand(title: "Quit Janus", key: "q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 6)
        .padding(.top, 5)
    }

    /// Opening a window from the menu bar is not enough on its own: the app is
    /// still in the background, so the window would appear behind whatever has
    /// focus.
    private func reveal() {
        dismiss()
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Pieces

/// A heading, its rows, and the last thing that went wrong in it.
private struct PanelSection<Content: View>: View {
    let title: String
    let isWorking: Bool
    let failure: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }

            content

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// One saved account: who it is, whether it is the one in use, and its limits.
private struct PanelAccountRow: View {
    let profile: Profile
    var detail: String?
    let isActive: Bool
    let isBusy: Bool
    let canRestore: Bool
    let reading: Reading?
    let now: Date
    let provider: String
    let incomplete: String
    var shortcut: KeyboardShortcut?
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 12)

                Text(profile.email)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isActive {
                    Text("In use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Switch", action: onSwitch)
                        .controlSize(.small)
                        .keyboardShortcut(shortcut)
                        .disabled(isBusy || !canRestore)
                }
            }

            figures.padding(.leading, 18)
        }
    }

    @ViewBuilder
    private var figures: some View {
        if !canRestore {
            Label(incomplete, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let reading, !reading.usage.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let window = reading.usage.fiveHour {
                    PanelLimit(caption: window.caption(otherwise: "5-hour"), window: window, now: now)
                }
                if let window = reading.usage.sevenDay {
                    PanelLimit(caption: window.caption(otherwise: "Weekly"), window: window, now: now)
                }

                // Orange once a window has turned over: the figures beside it are
                // the spend of a window that has ended, and the colour says so
                // without a sentence explaining it.
                Text(Freshness.line(source: reading.source,
                                    measuredAt: reading.usage.measuredAt,
                                    now: now,
                                    provider: provider))
                    .font(.caption2)
                    .foregroundStyle(reading.usage.resetWindows(by: now).isEmpty
                                     ? AnyShapeStyle(.tertiary)
                                     : AnyShapeStyle(Color.orange))
            }
        } else {
            Text("No figures yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// One limit across the panel's width: name, bar, percentage, countdown.
private struct PanelLimit: View {
    let caption: String
    let window: Usage.Window
    let now: Date

    var body: some View {
        let hasReset = window.hasReset(by: now)

        HStack(spacing: 8) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Meter(window: window, now: now)
                .frame(height: 5)

            // Coloured from half way up, the same point the bar turns yellow, so
            // the number catches the eye at the moment the bar starts to.
            Text(hasReset ? "—" : "\(window.percentUsed)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(hasReset ? AnyShapeStyle(.tertiary)
                                 : window.percentUsed >= 50 ? AnyShapeStyle(window.tint)
                                 : AnyShapeStyle(.primary))
                .frame(width: 36, alignment: .trailing)

            Text(Elapsed.until(window.resetsAt, now: now) ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
        }
    }
}

/// The signed-in account, when Janus has not saved it yet.
private struct UnsavedRow: View {
    let name: String
    let isBusy: Bool
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.plus")
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 12)
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Save", action: onSave)
                .controlSize(.small)
                .disabled(isBusy)
        }
    }
}

private struct SignedOutRow: View {
    var body: some View {
        Text("Not signed in")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// A row that behaves like a menu item: full width, highlighted under the
/// pointer, with its shortcut on the right.
private struct PanelCommand: View {
    let title: String
    let key: Character
    var isEnabled = true
    let action: () -> Void

    @State private var hovering = false

    private var highlighted: Bool { hovering && isEnabled }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text("⌘\(String(key).uppercased())")
                    .foregroundStyle(highlighted ? AnyShapeStyle(Color.white.opacity(0.8))
                                     : AnyShapeStyle(.tertiary))
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(Color.white)
                             : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(highlighted ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
    }
}
