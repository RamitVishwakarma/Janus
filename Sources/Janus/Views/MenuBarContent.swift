import AppKit
import SwiftUI
import JanusCore

/// The menu bar dropdown: current account, one-click switch, and a way in.
struct MenuBarContent: View {

    @ObservedObject var accounts: AccountsModel
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

        Button(storageTitle) {
            caches.scan()
            reveal()
        }

        Divider()

        Button("Open Janus…") { reveal() }
            .keyboardShortcut("o")
        Button("Refresh") {
            accounts.reload()
            caches.scan()
        }
        Button("Quit Janus") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var header: some View {
        if let active = accounts.active {
            Text("Signed in as \(active.email)")
            if let usage = accounts.usage[active.id] {
                if let week = usage.sevenDay {
                    Text("Weekly limit \(week.percentUsed)% used")
                }
                if let resets = Elapsed.until(usage.sevenDay?.resetsAt) {
                    Text(resets.prefix(1).uppercased() + resets.dropFirst())
                }
            }
        } else if let email = accounts.signedInEmail {
            Text("Signed in as \(email), not saved yet")
        } else {
            Text("No account signed in")
        }
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
