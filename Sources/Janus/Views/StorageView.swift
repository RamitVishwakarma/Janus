import SwiftUI
import JanusCore

/// The cache list: what each one is, how big it is, and whether it can go now.
struct StorageView: View {

    @ObservedObject var model: CachesModel

    var body: some View {
        VStack(spacing: 0) {
            Text("Everything here goes to the Trash rather than being deleted, so any choice can be taken back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

            Divider()

            if model.readings.isEmpty {
                placeholder
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.readings) { reading in
                            CacheRow(reading: reading, model: model)
                            Divider()
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .onAppear { model.scan() }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "internaldrive")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No caches found").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button("Select all") { model.selectAll() }
                    .buttonStyle(.link)
                Button("Select none") { model.selectNone() }
                    .buttonStyle(.link)

                if model.isScanning { ProgressView().controlSize(.small) }

                Spacer(minLength: 8)

                Button("Rescan") { model.scan() }

                Button("Move \(DiskUsage.describe(model.chosenBytes)) to Trash") {
                    model.clear()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.chosenBytes == 0)
            }

            if let report = model.report {
                Text(report.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.blockedCount > 0 {
                Text("\(model.blockedCount) held by a running app. Quit it to include it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }
}

private struct CacheRow: View {
    let reading: CacheReading
    @ObservedObject var model: CachesModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { model.isChosen(reading) },
                set: { model.choose(reading, $0) }
            ))
            .labelsHidden()
            .disabled(reading.isBlocked)

            VStack(alignment: .leading, spacing: 3) {
                Text(reading.entry.name).font(.body.weight(.medium))

                Text(reading.entry.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(reading.entry.displayPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if reading.isBlocked {
                    HStack(spacing: 8) {
                        Label("\(reading.runningOwner ?? "Its app") is running",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)

                        Button("Quit it") { model.quitOwner(of: reading) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            Text(DiskUsage.describe(reading.bytes))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(reading.isBlocked ? .tertiary : .primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .opacity(reading.isBlocked ? 0.62 : 1)
    }
}
