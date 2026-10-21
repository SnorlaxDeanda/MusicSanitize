import Foundation
import SwiftUI
import AppKit

// MARK: - App State (central ViewModel)

@MainActor
class AppState: ObservableObject {

    // MARK: - Published state
    @Published var scanRoot: URL?
    @Published var files: [AudioFile] = []
    @Published var selectedFileID: UUID?
    @Published var isScanning   = false
    @Published var isApplying   = false
    @Published var scanProgress: Double = 0
    @Published var scanStatus:  String  = ""
    @Published var lastReport:  FixReport?
    @Published var showDiffSheet   = false
    @Published var showReportSheet = false
    @Published var errorMessage: String?
    @Published var filterKind: IssueKind?
    @Published var filterShowOnlyIssues = false
    @Published var sortOrder: SortOrder = .filename

    let settings = ScanSettings()
    private var scanService: ScanService?
    private var fixService:  FixService?

    // MARK: - Derived

    var filteredFiles: [AudioFile] {
        var result = files
        if filterShowOnlyIssues { result = result.filter { $0.hasIssues } }
        if let kind = filterKind {
            result = result.filter { $0.issues.contains { $0.kind == kind } }
        }
        switch sortOrder {
        case .filename:   result.sort { $0.filename < $1.filename }
        case .issueCount: result.sort { $0.issueCount > $1.issueCount }
        case .artist:     result.sort { ($0.tags.artist ?? "") < ($1.tags.artist ?? "") }
        case .album:      result.sort { ($0.tags.album  ?? "") < ($1.tags.album  ?? "") }
        }
        return result
    }

    var selectedFile: AudioFile? {
        guard let id = selectedFileID else { return nil }
        return files.first { $0.id == id }
    }

    var totalIssues: Int   { files.reduce(0) { $0 + $1.issueCount } }
    var affectedFiles: Int { files.filter { $0.hasIssues }.count }
    var selectedCount: Int { files.filter { $0.isSelected }.count }

    var issueBreakdown: [(IssueKind, Int)] {
        var counts: [IssueKind: Int] = [:]
        for file in files {
            for issue in file.issues {
                counts[issue.kind, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }
    }

    // MARK: - Folder selection

    func requestFolderSelection() {
        let panel = NSOpenPanel()
        panel.canChooseFiles      = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Music Folder"
        panel.message = "Choose the root folder of your music library"

        // NSOpenPanel dismissal itself triggers SwiftUI view updates. Mutating
        // @Published synchronously here races that pass and triggers:
        // "Publishing changes from within view updates is not allowed…"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        publishAfterViewUpdate { [weak self] in
            self?.scanRoot = url
            self?.files = []
            self?.lastReport = nil
            self?.selectedFileID = nil
            self?.errorMessage = nil
        }
    }

    // MARK: - Scan

    func scan() async {
        guard let root = scanRoot else { return }
        isScanning = true
        scanProgress = 0
        scanStatus = ""
        files = []
        selectedFileID = nil
        errorMessage = nil

        let service = ScanService(settings: settings)
        scanService = service

        let progress = ProgressPublisher { [weak self] value, status in
            self?.scanProgress = value
            self?.scanStatus = status
        }

        do {
            let result = try await service.scan(root: root) { value, status in
                progress.update(value, status: status)
            }
            await progress.flush()
            files = result
        } catch {
            errorMessage = error.localizedDescription
        }

        isScanning = false
        scanStatus = ""
        scanProgress = 0
    }

    // MARK: - Toggle selection

    func toggleSelection(_ file: AudioFile) {
        if let i = files.firstIndex(where: { $0.id == file.id }) {
            files[i].isSelected.toggle()
        }
    }

    func selectAll()   { for i in files.indices { files[i].isSelected = true  } }
    func deselectAll() { for i in files.indices { files[i].isSelected = false } }
    func selectOnlyIssues() {
        for i in files.indices { files[i].isSelected = files[i].hasIssues }
    }

    // MARK: - Apply fixes

    func applyFixes() async {
        guard let root = scanRoot else { return }
        isApplying = true
        scanProgress = 0
        scanStatus = ""
        errorMessage = nil

        let service = FixService(settings: settings)
        fixService = service

        let progress = ProgressPublisher { [weak self] value, status in
            self?.scanProgress = value
            self?.scanStatus = status
        }

        do {
            let report = try await service.applyFixes(
                to: files, root: root
            ) { value, status in
                progress.update(value, status: status)
            }
            await progress.flush()
            lastReport = report
            // Present the sheet on the next turn — applying often completes
            // while the progress UI is still tearing down.
            publishAfterViewUpdate { [weak self] in
                self?.showReportSheet = true
            }
            await scan()
        } catch {
            errorMessage = error.localizedDescription
        }

        isApplying = false
        scanStatus = ""
        scanProgress = 0
    }

    // MARK: - Export report

    func exportCSV() {
        guard let report = lastReport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MusicSanitizer_Report.csv"
        panel.allowedContentTypes  = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.csvString.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Safe publishing

    /// Schedules work for the next main run-loop turn, after any in-flight
    /// SwiftUI view update (modal dismissal, layout pass, etc.) has finished.
    func publishAfterViewUpdate(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}

// MARK: - Progress coalescing

/// Forwards progress onto the main queue at most once per run-loop turn.
/// `DispatchQueue.main.async` (not `Task { @MainActor }`) is intentional:
/// unstructured main-actor tasks can still run inside SwiftUI's current
/// update, which produces the publishing warning when scanning a folder.
final class ProgressPublisher: @unchecked Sendable {
    private let apply: @MainActor (Double, String) -> Void
    private let lock = NSLock()
    private var pending: (Double, String)?
    private var scheduled = false

    init(apply: @escaping @MainActor (Double, String) -> Void) {
        self.apply = apply
    }

    func update(_ value: Double, status: String) {
        lock.lock()
        pending = (value, status)
        let needsSchedule = !scheduled
        if needsSchedule { scheduled = true }
        lock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.deliverOnMain(completion: nil)
        }
    }

    /// Ensures the latest progress value is applied before continuing.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.deliverOnMain {
                    continuation.resume()
                }
            }
        }
    }

    /// Called from `DispatchQueue.main.async` so we are outside SwiftUI's
    /// view-update window. The nested MainActor task then publishes safely.
    private func deliverOnMain(completion: (() -> Void)?) {
        lock.lock()
        let next = pending
        pending = nil
        scheduled = false
        lock.unlock()

        Task { @MainActor in
            if let next {
                apply(next.0, next.1)
            }
            completion?()
        }
    }
}

enum SortOrder: String, CaseIterable {
    case filename   = "Filename"
    case issueCount = "Issue Count"
    case artist     = "Artist"
    case album      = "Album"
}
