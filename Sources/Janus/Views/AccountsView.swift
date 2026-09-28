import SwiftUI
import JanusCore

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
                                reading: model.reading(for: profile),
                                now: model.now,
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
                   detail: "Save it and Janus can bring it back later without another sign-in.",
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

                Button("Refresh") { model.refresh() }
                    .disabled(model.isWorking)
            }

            Message(outcome: model.outcome, failure: model.failure)
        }
        .padding(16)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adding another account").font(.headline)
            Text("""
                 Janus saves whichever account is signed in right now. It \
                 cannot sign in for you.

                 To add a second one: sign out of Claude Code, sign in as the other \
                 account, then come back and press Save current account. From then on \
                 both are one click apart.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            Text("Where the usage figures come from").font(.headline)
            Text("""
                 Claude Code asks Anthropic for your limits while a session is \
                 running and writes the answer into its own settings file. Janus \
                 reads that file for free, which is what every row shows to begin \
                 with — and for an account that is not signed in, the last thing \
                 written there is however much it had spent when you switched away.

                 Refresh goes further and asks Anthropic directly, for every \
                 account, using the tokens each one already has saved. That is the \
                 only request Janus makes for Claude, it goes to nowhere but Anthropic, \
                 and nothing happens without you pressing the button. The line under \
                 each pair of bars says which of the two you are looking at.

                 A limit past its reset still shows a dash until it is fetched. The \
                 old figure belongs to a window that has ended, and guessing at its \
                 replacement would be worse than admitting there isn't one yet.
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

/// One saved account: its place in the rotation, its figures, and the buttons
/// that act on it. Shared by the Claude and Codex lists.
struct AccountRow: View {
    let profile: Profile
    let position: Int
    let isActive: Bool
    let isBusy: Bool
    let reading: Reading?
    let now: Date
    let canRestore: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSwitch: () -> Void
    let onRemove: () -> Void

    /// Who the figures were fetched from, for the line under the bars.
    var provider = "Anthropic"

    /// A word beside the name, such as the plan, for telling apart two accounts
    /// that share an email.
    var detail: String?

    /// What to say in place of figures, for an account that has none yet.
    var unmeasured = "No usage recorded yet"

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
                HStack(spacing: 6) {
                    Text(profile.email)
                        .font(.body.weight(isActive ? .semibold : .regular))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !canRestore {
                    Label("Saved session incomplete. Sign in as this account and save again",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let reading, !reading.usage.isEmpty {
                    UsagePanel(usage: reading.usage, source: reading.source, now: now,
                               provider: provider)
                } else {
                    Text(isActive ? "Signed in" : unmeasured)
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
