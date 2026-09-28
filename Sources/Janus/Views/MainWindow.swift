import SwiftUI
import JanusCore

/// The window. One tab for each tool whose accounts it switches, and one for
/// the caches.
struct MainWindow: View {

    @ObservedObject var accounts: AccountsModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var caches: CachesModel

    @State private var section: Section = .claude

    enum Section: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case codex = "Codex"
        case storage = "Storage"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch section {
            case .claude:  AccountsView(model: accounts)
            case .codex:   CodexView(model: codex)
            case .storage: StorageView(model: caches)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            accounts.reload()
            codex.reload()
            caches.scan()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Spacer()

            Text(Build.displayVersion)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
