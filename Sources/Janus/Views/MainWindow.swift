import SwiftUI
import JanusCore

/// The window. One tab for each tool whose accounts it switches.
struct MainWindow: View {

    @ObservedObject var accounts: AccountsModel
    @ObservedObject var codex: CodexModel

    @State private var section: Section = .claude

    enum Section: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case codex = "Codex"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch section {
            case .claude: AccountsView(model: accounts)
            case .codex:  CodexView(model: codex)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            accounts.reload()
            codex.reload()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            Text(Build.displayVersion)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
