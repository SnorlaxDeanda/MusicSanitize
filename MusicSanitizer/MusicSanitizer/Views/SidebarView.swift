import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            // Summary section
            Section("Library") {
                SidebarStat(label: "Total Files", value: "\(appState.files.count)", icon: "music.note")
                SidebarStat(label: "With Issues", value: "\(appState.affectedFiles)", icon: "exclamationmark.triangle",
                            color: appState.affectedFiles > 0 ? .yellow : .secondary)
                SidebarStat(label: "Total Issues", value: "\(appState.totalIssues)", icon: "list.bullet.clipboard",
                            color: appState.totalIssues > 0 ? .orange : .secondary)
            }

            // Issue filter
            if !appState.issueBreakdown.isEmpty {
                Section("Filter by Issue") {
                    Button(action: {
                        appState.publishAfterViewUpdate { appState.filterKind = nil }
                    }) {
                        Label {
                            HStack {
                                Text("All Files")
                                Spacer()
                                Text("\(appState.files.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        } icon: {
                            Image(systemName: "music.note.list")
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(appState.filterKind == nil ? Color.accentColor.opacity(0.15) : Color.clear)

                    ForEach(appState.issueBreakdown, id: \.0) { kind, count in
                        Button(action: {
                            appState.publishAfterViewUpdate { appState.filterKind = kind }
                        }) {
                            Label {
                                HStack {
                                    Text(kind.rawValue)
                                        .font(.callout)
                                    Spacer()
                                    Text("\(count)")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            } icon: {
                                Image(systemName: issueIcon(kind))
                                    .foregroundStyle(issueColor(kind))
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(appState.filterKind == kind ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                }
            }

            // Selection actions
            if !appState.files.isEmpty {
                Section("Select") {
                    Button("All Files")        { appState.selectAll() }
                    Button("Only with Issues") { appState.selectOnlyIssues() }
                    Button("None")             { appState.deselectAll() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            if !appState.duplicateGroups.isEmpty {
                Section("Duplicates") {
                    Button {
                        appState.publishAfterViewUpdate {
                            appState.showDuplicateSheet = true
                        }
                    } label: {
                        Label {
                            HStack {
                                Text("Review & Delete…")
                                Spacer()
                                Text("\(appState.duplicateGroups.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Music Sanitizer")
    }

    func issueIcon(_ kind: IssueKind) -> String {
        switch kind {
        case .missingTitle, .missingArtist, .missingAlbum, .missingYear, .missingTrackNumber:
            return "tag"
        case .missingArtwork:   return "photo"
        case .oversizedArtwork: return "photo.badge.exclamationmark"
        case .illegalFilenameChars, .nonStandardNaming: return "textformat"
        case .wrongFolder:      return "folder.badge.questionmark"
        case .duplicate:        return "doc.on.doc"
        case .extensionMismatch: return "exclamationmark.triangle"
        case .malformedTag:     return "tag.slash"
        }
    }

    func issueColor(_ kind: IssueKind) -> Color {
        switch kind {
        case .illegalFilenameChars, .extensionMismatch, .malformedTag: return .red
        case .duplicate, .oversizedArtwork: return .orange
        default: return .yellow
        }
    }
}

struct SidebarStat: View {
    let label: String
    let value: String
    let icon: String
    var color: Color = .secondary

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
