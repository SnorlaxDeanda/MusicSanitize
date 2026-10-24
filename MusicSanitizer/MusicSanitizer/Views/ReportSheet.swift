import SwiftUI

struct ReportSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var report: FixReport? { appState.lastReport }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Fix Report")
                        .font(.title2).bold()
                    if let report {
                        Text("\(report.successCount) succeeded · \(report.errorCount) errors")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
            }
            .padding()
            .background(.bar)

            Divider()

            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Summary cards
                        HStack(spacing: 12) {
                            StatCard(label: "Processed", value: "\(report.results.count)",   icon: "music.note",            color: .blue)
                            StatCard(label: "Fixed",     value: "\(report.successCount)",    icon: "checkmark.circle.fill", color: .green)
                            StatCard(label: "Errors",    value: "\(report.errorCount)",      icon: "xmark.circle.fill",     color: .red)
                            if let backup = report.backupLocation {
                                StatCard(label: "Backed Up", value: backup.lastPathComponent,
                                         icon: "archivebox.fill", color: .orange)
                            }
                        }
                        .padding(.horizontal)

                        Divider()

                        // Per-file results
                        ForEach(report.results.filter { !$0.errors.isEmpty }, id: \.file.id) { result in
                            ErrorResultRow(result: result)
                                .padding(.horizontal)
                        }

                        if report.errorCount == 0 {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(.green)
                                    Text("All files processed successfully!")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.top, 20)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }

            Divider()

            HStack {
                if report?.backupLocation != nil {
                    Button("Reveal Backup in Finder") {
                        if let url = report?.backupLocation {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button("Export CSV") { appState.exportCSV() }
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.bar)
        }
    }
}

struct StatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title3).bold()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ErrorResultRow: View {
    let result: FileFixResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.file.filename).font(.callout).bold()
                    Text(result.file.url.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            ForEach(Array(result.errors.enumerated()), id: \.offset) { _, err in
                Text("• " + err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
        .padding(10)
        .background(.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
