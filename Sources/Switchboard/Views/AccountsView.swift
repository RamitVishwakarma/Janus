import SwiftUI
import SwitchboardCore

/// The account list, in the order the rotation visits it.
struct AccountsView: View {

    @ObservedObject var model: AccountsModel
    @State private var pendingRemoval: Profile?
    @State private var showingHelp = false

    var body: some View {
        VStack(spacing: 0) {
            if model.profiles.isEmpty {
                EmptyAccounts(model: model)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        notices

                        Text("Switching moves down this list and wraps around.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 9)

                        Divider()

                        let profiles = model.profiles
                        ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                            AccountRow(
                                profile: profile,
                                position: index + 1,
                                isActive: model.isActive(profile),
                                isBusy: model.isWorking,
                                usage: model.usage[profile.id],
                                canRestore: model.canRestore(profile),
                                canMoveUp: index > 0,
                                canMoveDown: index < profiles.count - 1,
                                onMoveUp: { model.move(profile, by: -1) },
                                onMoveDown: { model.move(profile, by: 1) },
                                onSwitch: { model.switchTo(profile) },
                                onRemove: { pendingRemoval = profile }
                            )
                            Divider()
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .confirmationDialog(
            "Stop managing \(pendingRemoval?.email ?? "this account")?",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let profile = pendingRemoval { model.remove(profile) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("""
                 Its saved session is deleted from this Mac, so switching back would \
                 mean signing in again. If it is the account signed in right now, that \
                 session keeps working.
                 """)
        }
    }

    /// Things worth fixing, surfaced where they can be fixed.
    @ViewBuilder
    private var notices: some View {
        if let email = model.signedInEmail, !model.currentAccountIsManaged {
            Notice(symbol: "person.badge.plus",
                   tint: .blue,
                   title: "\(email) is signed in but not saved",
                   detail: "Save it and Switchboard can bring it back later without another sign-in.",
                   actionTitle: "Save",
                   action: { model.addCurrentAccount() })
        }

        let broken = model.profiles.filter { !model.canRestore($0) }
        if !broken.isEmpty {
            Notice(symbol: "exclamationmark.triangle",
                   tint: .orange,
                   title: "\(broken.count) saved \(broken.count == 1 ? "session is" : "sessions are") incomplete",
                   detail: "Sign in as \(broken.map(\.email).joined(separator: ", ")) and save again to repair.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    model.addCurrentAccount()
                } label: {
                    Label("Save current account", systemImage: "plus")
                }
                .disabled(model.isWorking)

                Button {
                    showingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingHelp, arrowEdge: .top) { help }

                if model.isWorking { ProgressView().controlSize(.small) }

                Spacer(minLength: 8)

                Button("Refresh") { model.reload() }
            }

            Message(outcome: model.outcome, failure: model.failure)
        }
        .padding(16)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adding another account").font(.headline)
            Text("""
                 Switchboard saves whichever account is signed in right now — it cannot \
                 sign in for you.

                 To add a second one: sign out of Claude Code, sign in as the other \
                 account, then come back and press Save current account. From then on \
                 both are one click apart.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct EmptyAccounts: View {
    @ObservedObject var model: AccountsModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text("No accounts saved yet").font(.title3)

            Text(model.signedInEmail.map {
                "You are signed in as \($0). Save it, then sign in as another account and save that one too."
            } ?? "Sign in to Claude Code, then come back and save the account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if model.signedInEmail != nil {
                Button("Save current account") { model.addCurrentAccount() }
                    .disabled(model.isWorking)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

private struct AccountRow: View {
    let profile: Profile
    let position: Int
    let isActive: Bool
    let isBusy: Bool
    let usage: Usage?
    let canRestore: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSwitch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveUp || isBusy)
                    .help("Move earlier in the rotation")
                Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveDown || isBusy)
                    .help("Move later in the rotation")
            }
            .font(.caption)

            Text("\(position)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.email)
                    .font(.body.weight(isActive ? .semibold : .regular))

                if !canRestore {
                    Label("Saved session incomplete — sign in as this account and save again",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let usage, !usage.isEmpty {
                    UsagePanel(usage: usage, isLive: isActive)
                } else {
                    Text(isActive ? "Signed in" : "No usage recorded yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if isActive {
                Text("In use")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Switch", action: onSwitch)
                    .disabled(isBusy || !canRestore)
            }

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
            .help("Stop managing this account")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
