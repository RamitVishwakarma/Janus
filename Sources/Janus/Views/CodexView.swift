import SwiftUI
import JanusCore

/// The Codex account list, in the order its rotation visits it.
struct CodexView: View {

    @ObservedObject var model: CodexModel
    @State private var pendingRemoval: Profile?
    @State private var showingHelp = false

    var body: some View {
        VStack(spacing: 0) {
            if model.profiles.isEmpty {
                empty
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
                                onRemove: { pendingRemoval = profile },
                                provider: "OpenAI",
                                detail: profile.plan.map { $0.capitalized },
                                unmeasured: "Press Refresh to fetch its limits"
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
            "Stop managing \(pendingRemoval?.email ?? "this account") for Codex?",
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
                 Its saved sign-in is deleted from this Mac, so switching back would \
                 mean signing in to Codex again. If it is the account signed in right \
                 now, Codex stays signed in.
                 """)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let name = model.signedInName, !model.currentAccountIsManaged {
            Notice(symbol: "person.badge.plus",
                   tint: .blue,
                   title: "\(name) is signed in to Codex but not saved",
                   detail: "Save it and Janus can bring it back later without another sign-in.",
                   actionTitle: "Save",
                   action: { model.addCurrentAccount() })
        }

        let broken = model.profiles.filter { !model.canRestore($0) }
        if !broken.isEmpty {
            Notice(symbol: "exclamationmark.triangle",
                   tint: .orange,
                   title: "\(broken.count) saved \(broken.count == 1 ? "sign-in is" : "sign-ins are") missing",
                   detail: "Sign in to Codex as \(broken.map(\.email).joined(separator: ", ")) and save again to repair.")
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text("No Codex accounts saved yet").font(.title3)

            Text(model.signedInName.map {
                "Codex is signed in as \($0). Save it, then sign in as another account and save that one too."
            } ?? "Sign in to Codex, then come back and save the account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if model.signedInName != nil {
                Button("Save current account") { model.addCurrentAccount() }
                    .disabled(model.isWorking)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
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
                 Codex keeps its sign-in in ~/.codex/auth.json, and Janus saves \
                 whichever account that file holds. It cannot sign in for you.

                 To add a second one: run codex logout, then codex login as the other \
                 account, then come back and press Save current account.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            Text("Before switching").font(.headline)
            Text("""
                 Quit Codex first. A running Codex keeps the account it started \
                 with, and when it renews its sign-in it writes that account back \
                 over the one you switched to.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            Text("Where the usage figures come from").font(.headline)
            Text("""
                 Refresh asks ChatGPT for each account's limits, using the sign-in \
                 each one already has saved: the same request Codex makes for \
                 /status. Nothing is fetched until you press it. Accounts signed in \
                 with an API key have no plan limits to show.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }
}
