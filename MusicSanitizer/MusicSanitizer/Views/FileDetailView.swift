import SwiftUI

struct FileDetailView: View {
    @EnvironmentObject var appState: AppState
    let file: AudioFile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.tags.title ?? file.url.deletingPathExtension().lastPathComponent)
                            .font(.title2).bold()
                        if let artist = file.tags.artist {
                            Text(artist).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let album = file.tags.album {
                            Text(album).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(file.format.rawValue)
                            .font(.caption).bold()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                        Text(file.formattedDuration)
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(file.formattedSize)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Divider()

                // Tags grid
                DetailSection(title: "Metadata") {
                    TagGrid(file: file)
                }

                Divider()

                // Issues list
                if file.hasIssues {
                    DetailSection(title: "Issues (\(file.issueCount))") {
                        VStack(spacing: 8) {
                            ForEach(file.issues.sorted { $0.severity > $1.severity }) { issue in
                                IssueRow(issue: issue)
                            }
                        }
                    }
                    Divider()
                }

                // Proposed path
                if let proposed = file.proposedURL {
                    DetailSection(title: "Proposed Location") {
                        VStack(alignment: .leading, spacing: 6) {
                            PathRow(label: "Current", url: file.url)
                            Image(systemName: "arrow.down")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                            PathRow(label: "After Fix", url: proposed, highlight: true)
                        }
                    }
                    Divider()
                }

                // File path
                DetailSection(title: "File Location") {
                    Text(file.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(20)
        }
        .background(.background)
    }
}

// MARK: - Supporting views

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
    }
}

struct TagGrid: View {
    let file: AudioFile

    private var rows: [(String, String)] {
        var r: [(String, String)] = []
        if let v = file.tags.title       { r.append(("Title", v)) }
        if let v = file.tags.artist      { r.append(("Artist", v)) }
        if let v = file.tags.albumArtist { r.append(("Album Artist", v)) }
        if let v = file.tags.album       { r.append(("Album", v)) }
        if let v = file.tags.genre       { r.append(("Genre", v)) }
        if let v = file.tags.year        { r.append(("Year", "\(v)")) }
        if let v = file.tags.trackNumber {
            let s = file.tags.trackTotal != nil ? "\(v) / \(file.tags.trackTotal!)" : "\(v)"
            r.append(("Track", s))
        }
        if let v = file.tags.composer    { r.append(("Composer", v)) }
        r.append(("Artwork", file.tags.hasEmbeddedArtwork ?
            (file.tags.artworkSize.map { "\($0 / 1024) KB" } ?? "Yes") : "None"))
        return r
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(value)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct IssueRow: View {
    let issue: FileIssue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.kind.rawValue).font(.callout).bold()
                Text(issue.description).font(.caption).foregroundStyle(.secondary)
                if let fix = issue.proposedFix {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                            .font(.caption2)
                        Text(fix).font(.caption2).foregroundStyle(.green)
                    }
                }
            }
            Spacer()
            if issue.autoFix {
                Text("Auto-fix")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .background(severityColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var severityIcon: String {
        switch issue.severity {
        case .error:   return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var severityColor: Color {
        switch issue.severity {
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .blue
        }
    }
}

struct PathRow: View {
    let label: String
    let url: URL
    var highlight: Bool = false

    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(url.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(highlight ? .green : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
