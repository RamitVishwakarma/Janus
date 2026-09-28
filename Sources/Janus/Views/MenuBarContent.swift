import AppKit
import SwiftUI
import JanusCore

/// The menu bar dropdown: current accounts, one-click switches, and a way in.
struct MenuBarContent: View {

    @ObservedObject var accounts: AccountsModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var caches: CachesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        header

        Divider()

        if accounts.isWorking {
            Text("Working…")
        } else if let next = accounts.next, accounts.canRestore(next) {
            Button("Switch to \(next.shortName)") { accounts.switchToNext() }
                .keyboardShortcut("s")
        } else if !accounts.currentAccountIsManaged {
            Button("Save this account") { accounts.addCurrentAccount() }
        }

        if accounts.profiles.count > 1 {
            Menu("Accounts") {
                ForEach(accounts.profiles) { profile in
                    Button(label(for: profile)) { accounts.switchTo(profile) }
                        .disabled(accounts.isActive(profile) || !accounts.canRestore(profile))
                }
            }
        }

        Divider()

        codexSection

        Divider()

        Button(storageTitle) {
            caches.scan()
            reveal()
        }

        Divider()

        Button("Open Janus…") { reveal() }
            .keyboardShortcut("o")
        Button("Refresh") {
            accounts.refresh()
            if !codex.profiles.isEmpty { codex.refresh() }
            caches.scan()
        }
        Button("Quit Janus") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var header: some View {
        if let active = accounts.active {
            Text("Signed in as \(active.email)")
            if let usage = accounts.reading(for: active)?.usage {
                if let week = usage.sevenDay, !week.hasReset(by: accounts.now) {
                    Text("Weekly limit \(week.percentUsed)% used")
                }
                if let resets = Elapsed.until(usage.sevenDay?.resetsAt, now: accounts.now) {
                    Text(resets.prefix(1).uppercased() + resets.dropFirst())
                }
            }
        } else if let email = accounts.signedInEmail {
            Text("Signed in as \(email), not saved yet")
        } else {
            Text("No account signed in")
        }
    }

    /// The same three things for Codex: who is signed in, the next account round,
    /// and the rest. No keyboard shortcut, so that ⌘S keeps meaning what it
    /// always has.
    @ViewBuilder
    private var codexSection: some View {
        if let active = codex.active {
            Text("Codex: \(active.email)")
        } else if let name = codex.signedInName {
            Text("Codex: \(name), not saved yet")
        } else {
            Text("Codex: not signed in")
        }

        if codex.isWorking {
            Text("Working…")
        } else if let next = codex.next, next.id != codex.active?.id, codex.canRestore(next) {
            Button("Switch Codex to \(next.shortName)") { codex.switchToNext() }
        } else if codex.signedInName != nil, !codex.currentAccountIsManaged {
            Button("Save this Codex account") { codex.addCurrentAccount() }
        }

        if codex.profiles.count > 1 {
            Menu("Codex accounts") {
                ForEach(codex.profiles) { profile in
                    Button(codexLabel(for: profile)) { codex.switchTo(profile) }
                        .disabled(codex.isActive(profile) || !codex.canRestore(profile))
                }
            }
        }
    }

    private func codexLabel(for profile: Profile) -> String {
        let marker = codex.isActive(profile) ? "●" : "○"
        let plan = profile.plan.map { " (\($0.capitalized))" } ?? ""
        return "\(marker)  \(profile.email)\(plan)"
    }

    private func label(for profile: Profile) -> String {
        let marker = accounts.isActive(profile) ? "●" : "○"
        return "\(marker)  \(profile.email)"
    }

    private var storageTitle: String {
        let bytes = caches.clearableBytes
        return bytes > 0 ? "Clear caches… (\(DiskUsage.describe(bytes)))" : "Clear caches…"
    }

    /// Opening a window from the menu bar is not enough on its own: the app is
    /// still in the background, so the window would appear behind whatever has
    /// focus.
    private func reveal() {
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }
}
