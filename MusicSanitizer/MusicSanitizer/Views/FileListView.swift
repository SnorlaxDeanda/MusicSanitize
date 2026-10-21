import SwiftUI

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar strip
            HStack(spacing: 8) {
                Toggle("Issues Only", isOn: appState.filterShowOnlyIssuesBinding)
                    .toggleStyle(.checkbox)
                    .font(.callout)

                Divider().frame(height: 16)

                Picker("Sort", selection: appState.sortOrderBinding) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Spacer()

                if appState.selectedCount > 0 {
                    Text("\(appState.selectedCount) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if appState.isScanning {
                ScanningView()
            } else if appState.filteredFiles.isEmpty {
                Group {
                    if appState.files.isEmpty {
                        EmptyDetailView()
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 48))
                                .foregroundStyle(.green)
                            Text("No issues found!")
                                .font(.title3)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                // Deferred selection binding — List clears invalid selection
                // during its own update when `files` is replaced after a scan.
                List(appState.filteredFiles, id: \.id, selection: appState.selectedFileIDBinding) { file in
                    FileRowView(file: file)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - File row

struct FileRowView: View {
    @EnvironmentObject var appState: AppState
    let file: AudioFile

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox
            Button(action: { appState.toggleSelection(file) }) {
                Image(systemName: file.isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(file.isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            // Format badge
            Text(file.format.rawValue)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(formatColor(file.format).opacity(0.2))
                .foregroundStyle(formatColor(file.format))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(file))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let artist = file.tags.artist, let album = file.tags.album {
                    Text("\(artist) — \(album)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Right side: duration, size, issue badges
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    ForEach(topIssues(file), id: \.id) { issue in
                        IssueBadge(severity: issue.severity)
                    }
                    if file.issueCount > 3 {
                        Text("+\(file.issueCount - 3)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(file.formattedDuration)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private func displayName(_ file: AudioFile) -> String {
        if let title = file.tags.title, !title.isEmpty { return title }
        return file.url.deletingPathExtension().lastPathComponent
    }

    private func topIssues(_ file: AudioFile) -> [FileIssue] {
        Array(file.issues.sorted { $0.severity > $1.severity }.prefix(3))
    }

    private func formatColor(_ format: AudioFormat) -> Color {
        switch format {
        case .mp3:  return .blue
        case .flac: return .green
        case .m4a:  return .purple
        case .aiff: return .orange
        default:    return .gray
        }
    }
}

struct IssueBadge: View {
    let severity: IssueSeverity

    var body: some View {
        Circle()
            .fill(badgeColor)
            .frame(width: 8, height: 8)
    }

    var badgeColor: Color {
        switch severity {
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .blue
        }
    }
}

struct ScanningView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: appState.scanProgress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)
            Text(appState.scanStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(Int(appState.scanProgress * 100))%")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
