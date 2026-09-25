import SwiftUI
import SwitchboardCore

/// The window. Two things the app does, one switch between them.
struct MainWindow: View {

    @ObservedObject var accounts: AccountsModel
    @ObservedObject var caches: CachesModel

    @State private var section: Section = .accounts

    enum Section: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case storage = "Storage"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch section {
            case .accounts: AccountsView(model: accounts)
            case .storage:  StorageView(model: caches)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            accounts.reload()
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
            .frame(width: 220)

            Spacer()

            Text(Build.displayVersion)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
