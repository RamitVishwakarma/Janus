import AppKit
import SwiftUI
import SwitchboardCore

@main
struct SwitchboardApp: App {

    @StateObject private var accounts = AccountsModel()
    @StateObject private var caches = CachesModel()

    var body: some Scene {
        // The window is the main surface. Everything the app does is visible in
        // it at once, which a menu bar dropdown is a poor place to discover.
        Window("Switchboard", id: WindowID.main) {
            MainWindow(accounts: accounts, caches: caches)
        }
        .defaultSize(width: 620, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Switchboard") { AboutPanel.show() }
            }
        }

        // The menu bar item is the shortcut: switch accounts without opening
        // anything, and see which account is live at a glance.
        MenuBarExtra {
            MenuBarContent(accounts: accounts, caches: caches)
        } label: {
            Label(menuBarTitle, systemImage: "arrow.left.arrow.right.circle")
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarTitle: String {
        accounts.active?.shortName ?? "Switchboard"
    }
}

enum WindowID {
    static let main = "switchboard.main"
}

/// The standard About panel, filled in from the bundle so the version shown is
/// always the version running.
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Build.version,
            .init(rawValue: "Copyright"): "MIT licensed. github.com/RamitVishwakarma/Switchboard"
        ])
    }
}
