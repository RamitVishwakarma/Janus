import AppKit
import SwiftUI
import JanusCore

@main
struct JanusApp: App {

    @StateObject private var accounts = AccountsModel()
    @StateObject private var codex = CodexModel()

    var body: some Scene {
        // The window is where accounts are saved, ordered and removed. Reading
        // the figures and switching are also in the menu bar panel below, so the
        // window need not be open to see which account has room left.
        Window("Janus", id: WindowID.main) {
            MainWindow(accounts: accounts, codex: codex)
        }
        .defaultSize(width: 620, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Janus") { AboutPanel.show() }
            }
        }

        // The menu bar item opens a panel with every account's limits and a
        // switch beside each. The title stays the Claude Code account, which is
        // the one that has always been there.
        MenuBarExtra {
            MenuBarPanel(accounts: accounts, codex: codex)
        } label: {
            Label(menuBarTitle, systemImage: "arrow.left.arrow.right.circle")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarTitle: String {
        accounts.active?.shortName ?? "Janus"
    }
}

enum WindowID {
    static let main = "janus.main"
}

/// The standard About panel, filled in from the bundle so the version shown is
/// always the version running.
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Build.version,
            .init(rawValue: "Copyright"): "MIT licensed. github.com/RamitVishwakarma/Janus"
        ])
    }
}
