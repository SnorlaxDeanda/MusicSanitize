import SwiftUI

/// Review duplicate groups, pick a keeper per group, and move extras to Trash.
struct DuplicateReviewSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selections: [UUID: UUID] = [:] // groupID → keepID
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var lastResult: String?

    private var groups: [DuplicateGroup] {
        appState.duplicateGroups
    }

    private var deleteCount: Int {
        groups.reduce(0) { partial, group in
            let keep = selections[group.id] ?? group.suggestedKeepID
            return partial + group.files.filter { $0.id != keep }.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groups) { group in
                            DuplicateGroupCard(
                                group: group,
                                keepID: Binding(
                                    get: { selections[group.id] ?? group.suggestedKeepID },
                                    set: { selections[group.id] = $0 }
                                )
                            )
                        }
                    }
                    .padding()
                }
            }

            Divider()
            footer
        }
        .onAppear { seedSelections() }
        .confirmationDialog(
            "Move \(deleteCount) duplicate file\(deleteCount == 1 ? "" : "s") to Trash?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One file is kept in each group. You can restore from Trash if needed.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Duplicates")
                    .font(.title2).bold()
                Text("\(groups.count) group\(groups.count == 1 ? "" : "s") · \(deleteCount) file\(deleteCount == 1 ? "" : "s") marked for Trash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
                .disabled(isDeleting)
        }
        .padding()
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("No duplicates found")
                .font(.title3)
            Text("Run a scan with duplicate detection enabled in Settings.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack {
            if let lastResult {
                Text(lastResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Keeps the best copy in each group (format, tags, size). Others go to Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset Suggestions") {
                seedSelections()
            }
            .disabled(isDeleting || groups.isEmpty)

            Button(isDeleting ? "Moving…" : "Move Duplicates to Trash") {
                confirmDelete = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isDeleting || deleteCount == 0)
            .keyboardShortcut(.return)
        }
        .padding()
        .background(.bar)
    }

    private func seedSelections() {
        var next: [UUID: UUID] = [:]
        for group in groups {
            next[group.id] = group.suggestedKeepID
        }
        selections = next
        lastResult = nil
    }

    private func performDelete() async {
        isDeleting = true
        lastResult = nil
        defer { isDeleting = false }

        var ids: [UUID] = []
        for group in groups {
            let keep = selections[group.id] ?? group.suggestedKeepID
            ids.append(contentsOf: group.files.filter { $0.id != keep }.map(\.id))
        }

        let result = await appState.deleteDuplicateFiles(ids: ids)
        if result.failed.isEmpty {
            lastResult = "Moved \(result.deleted) file\(result.deleted == 1 ? "" : "s") to Trash."
            if appState.duplicateGroups.isEmpty {
                dismiss()
            } else {
                seedSelections()
            }
        } else {
            lastResult = "Moved \(result.deleted); \(result.failed.count) failed."
            seedSelections()
        }
    }
}

// MARK: - Group card

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @Binding var keepID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(group.files.count) copies", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Text(group.summaryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(group.files) { file in
                DuplicateFileRow(
                    file: file,
                    isKeeper: file.id == keepID,
                    onKeep: { keepID = file.id }
                )
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DuplicateFileRow: View {
    let file: AudioFile
    let isKeeper: Bool
    let onKeep: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onKeep) {
                Image(systemName: isKeeper ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isKeeper ? Color.green : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(isKeeper ? "Keeping this file" : "Keep this file instead")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(file.tags.title ?? file.filename)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(file.format.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    if isKeeper {
                        Text("KEEP")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                    }
                }

                if let artist = file.tags.artist {
                    Text(artist + (file.tags.album.map { " — \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(file.url.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text("\(file.formattedDuration) · \(file.formattedSize)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(isKeeper ? Color.green.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
