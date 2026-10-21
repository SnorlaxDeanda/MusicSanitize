import SwiftUI

struct DiffPreviewSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var filesWithIssues: [AudioFile] {
        appState.files.filter { $0.isSelected && $0.hasIssues }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Preview Changes")
                        .font(.title2).bold()
                    Text("\(filesWithIssues.count) files · \(totalChanges) proposed changes")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()
            .background(.bar)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filesWithIssues) { file in
                        DiffFileRow(file: file)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            // Footer action bar
            HStack {
                Button("Export as CSV") {
                    appState.exportCSV()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text("Originals backed up to \(appState.settings.backupFolderName)/")
                    .font(.caption).foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") { dismiss() }

                Button("Apply \(filesWithIssues.count) Files") {
                    dismiss()
                    Task { await appState.applyFixes() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(filesWithIssues.isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }

    var totalChanges: Int {
        filesWithIssues.reduce(0) { $0 + $1.issues.filter(\.autoFix).count }
    }
}

struct DiffFileRow: View {
    let file: AudioFile
    @State private var expanded = true

    var autoFixable: [FileIssue] { file.issues.filter(\.autoFix) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                    Text(file.url.lastPathComponent)
                        .font(.callout).bold()
                    Spacer()
                    Text("\(autoFixable.count) change\(autoFixable.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(autoFixable) { issue in
                        DiffLine(issue: issue)
                    }
                    if let proposed = file.proposedURL, proposed != file.url {
                        DiffMoveLine(from: file.url, to: proposed)
                    }
                }
                .padding(.leading, 30)
                .padding(.trailing, 16)
                .padding(.bottom, 8)
            }
        }
        .background(.background)
    }
}

struct DiffLine: View {
    let issue: FileIssue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text(issue.kind.rawValue + ":")
                .font(.system(size: 11)).bold()
                .foregroundStyle(.secondary)
            if let fix = issue.proposedFix {
                Text(fix)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green)
            } else {
                Text(issue.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DiffMoveLine: View {
    let from: URL
    let to: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red).font(.caption)
                Text(from.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.caption)
                Text(to.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
