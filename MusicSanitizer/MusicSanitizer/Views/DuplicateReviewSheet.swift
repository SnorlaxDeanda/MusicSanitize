import SwiftUI

/// Review duplicate groups in pages of ~100, pick a keeper per group, and
/// move extras on the current page to Trash.
struct DuplicateReviewSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private static let pageSize = 100

    @State private var selections: [UUID: UUID] = [:] // groupID → keepID
    @State private var pageIndex = 0
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var lastResult: String?

    private var groups: [DuplicateGroup] {
        appState.duplicateGroups
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(groups.count) / Double(Self.pageSize))))
    }

    private var safePageIndex: Int {
        min(max(0, pageIndex), pageCount - 1)
    }

    private var pageGroups: [DuplicateGroup] {
        guard !groups.isEmpty else { return [] }
        let start = safePageIndex * Self.pageSize
        let end = min(start + Self.pageSize, groups.count)
        return Array(groups[start..<end])
    }

    private var pageRangeLabel: String {
        guard !groups.isEmpty else { return "0 groups" }
        let start = safePageIndex * Self.pageSize + 1
        let end = min((safePageIndex + 1) * Self.pageSize, groups.count)
        return "Groups \(start)–\(end) of \(groups.count)"
    }

    /// Trash count for the *current page only* — keeps large libraries manageable.
    private var pageDeleteCount: Int {
        pageGroups.reduce(0) { partial, group in
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
                if pageCount > 1 {
                    pageBar
                    Divider()
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(pageGroups) { group in
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
                    .id(safePageIndex) // reset scroll position when flipping pages
                }
            }

            Divider()
            footer
        }
        .onAppear {
            seedSelections(for: pageGroups)
            clampPage()
        }
        .onChange(of: groups.count) { _ in
            clampPage()
            seedSelections(for: pageGroups)
        }
        .confirmationDialog(
            "Move \(pageDeleteCount) duplicate file\(pageDeleteCount == 1 ? "" : "s") on this page to Trash?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Move This Page to Trash", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the \(pageGroups.count) group\(pageGroups.count == 1 ? "" : "s") on this page are affected. Other pages are left alone. You can restore from Trash if needed.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Duplicates")
                    .font(.title2).bold()
                Text("\(pageRangeLabel) · \(pageDeleteCount) on this page marked for Trash")
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

    private var pageBar: some View {
        HStack(spacing: 12) {
            Button {
                goToPage(safePageIndex - 1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(isDeleting || safePageIndex == 0)

            Spacer()

            Text("Page \(safePageIndex + 1) of \(pageCount)")
                .font(.callout.weight(.medium))
                .monospacedDigit()

            Spacer()

            Button {
                goToPage(safePageIndex + 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(isDeleting || safePageIndex >= pageCount - 1)
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal)
        .padding(.vertical, 8)
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
            } else if pageCount > 1 {
                Text("Reviewing \(Self.pageSize) groups at a time. Trash only affects this page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Keeps the best copy in each group (format, tags, size). Others go to Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset Page") {
                seedSelections(for: pageGroups)
            }
            .disabled(isDeleting || pageGroups.isEmpty)

            Button(isDeleting ? "Moving…" : "Move This Page to Trash") {
                confirmDelete = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isDeleting || pageDeleteCount == 0)
            .keyboardShortcut(.return)
        }
        .padding()
        .background(.bar)
    }

    private func goToPage(_ index: Int) {
        guard !isDeleting else { return }
        pageIndex = min(max(0, index), pageCount - 1)
        seedSelections(for: pageGroups)
        lastResult = nil
    }

    private func clampPage() {
        pageIndex = min(max(0, pageIndex), max(0, pageCount - 1))
    }

    private func seedSelections(for page: [DuplicateGroup]) {
        var next = selections
        for group in page {
            if next[group.id] == nil {
                next[group.id] = group.suggestedKeepID
            } else if !group.files.contains(where: { $0.id == next[group.id] }) {
                next[group.id] = group.suggestedKeepID
            }
        }
        selections = next
        lastResult = nil
    }

    private func performDelete() async {
        isDeleting = true
        lastResult = nil
        defer { isDeleting = false }

        let page = pageGroups
        var ids: [UUID] = []
        for group in page {
            let keep = selections[group.id] ?? group.suggestedKeepID
            ids.append(contentsOf: group.files.filter { $0.id != keep }.map(\.id))
        }

        let result = await appState.deleteDuplicateFiles(ids: ids)
        if result.failed.isEmpty {
            lastResult = "Moved \(result.deleted) file\(result.deleted == 1 ? "" : "s") to Trash from this page."
            if appState.duplicateGroups.isEmpty {
                dismiss()
            } else {
                clampPage()
                seedSelections(for: pageGroups)
            }
        } else {
            lastResult = "Moved \(result.deleted); \(result.failed.count) failed."
            clampPage()
            seedSelections(for: pageGroups)
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
