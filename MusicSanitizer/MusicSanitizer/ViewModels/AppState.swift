import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    // MARK: - Deferred bindings
    //
    // SwiftUI often writes presentation/selection bindings *during* a view
    // update (sheet dismiss, List clearing invalid selection, Toggle, etc.).
    // Writing @Published in that window triggers:
    // "Publishing changes from within view updates is not allowed…"
    // These bindings hop to the next main run-loop turn before mutating state.

    var selectedFileIDBinding: Binding<UUID?> {
        deferredBinding(\.selectedFileID)
    }

    var filterShowOnlyIssuesBinding: Binding<Bool> {
        deferredBinding(\.filterShowOnlyIssues)
    }

    var sortOrderBinding: Binding<SortOrder> {
        deferredBinding(\.sortOrder)
    }

    var showDiffSheetBinding: Binding<Bool> {
        deferredBinding(\.showDiffSheet)
    }

    var showReportSheetBinding: Binding<Bool> {
        deferredBinding(\.showReportSheet)
    }

    var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { self.errorMessage != nil },
            set: { newValue in
                guard !newValue else { return }
                self.publishAfterViewUpdate { [weak self] in
                    self?.errorMessage = nil
                }
            }
        )
    }

    func deferredBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<AppState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { [weak self] newValue in
                DispatchQueue.main.async {
                    self?[keyPath: keyPath] = newValue
                }
            }
        )
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
        // @Published here races that pass and triggers the publishing warning.
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

        // Let the triggering control's view update finish first.
        await Task.yield()

        isScanning = true
        scanProgress = 0
        scanStatus = "Starting…"
        selectedFileID = nil
        errorMessage = nil
        files = []

        let service = ScanService(settings: settings)
        scanService = service

        let progress = ProgressPublisher()
        progress.attach(self)
        defer { progress.detach() }

        do {
            let result = try await service.scan(root: root) { value, status in
                progress.update(value, status: status)
            }
            await progress.flush(into: self)
            // Yield so the last progress-driven render can complete before we
            // swap the file list and tear down the scanning UI.
            await Task.yield()
            files = result
        } catch {
            errorMessage = error.localizedDescription
        }

        await Task.yield()
        isScanning = false
        scanStatus = ""
        scanProgress = 0
    }

    // MARK: - Toggle selection

    func toggleSelection(_ file: AudioFile) {
        // Defer so the row button's view update isn't still in flight.
        publishAfterViewUpdate { [weak self] in
            guard let self,
                  let i = self.files.firstIndex(where: { $0.id == file.id }) else { return }
            self.files[i].isSelected.toggle()
        }
    }

    func selectAll() {
        publishAfterViewUpdate { [weak self] in
            guard let self else { return }
            for i in self.files.indices { self.files[i].isSelected = true }
        }
    }

    func deselectAll() {
        publishAfterViewUpdate { [weak self] in
            guard let self else { return }
            for i in self.files.indices { self.files[i].isSelected = false }
        }
    }

    func selectOnlyIssues() {
        publishAfterViewUpdate { [weak self] in
            guard let self else { return }
            for i in self.files.indices {
                self.files[i].isSelected = self.files[i].hasIssues
            }
        }
    }

    // MARK: - Apply fixes

    func applyFixes() async {
        guard let root = scanRoot else { return }

        await Task.yield()

        isApplying = true
        scanProgress = 0
        scanStatus = "Starting…"
        errorMessage = nil

        let service = FixService(settings: settings)
        fixService = service

        let progress = ProgressPublisher()
        progress.attach(self)
        defer { progress.detach() }

        do {
            let report = try await service.applyFixes(
                to: files, root: root
            ) { value, status in
                progress.update(value, status: status)
            }
            await progress.flush(into: self)
            await Task.yield()
            lastReport = report
            publishAfterViewUpdate { [weak self] in
                self?.showReportSheet = true
            }
            await scan()
        } catch {
            errorMessage = error.localizedDescription
        }

        await Task.yield()
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

/// Delivers progress on the next main run-loop turn, applying state
/// *synchronously* inside `DispatchQueue.main.async`.
///
/// Important: do **not** wrap the apply in `Task { @MainActor in … }`.
/// Unstructured main-actor tasks can still execute inside SwiftUI's current
/// update pass and re-trigger the publishing warning.
final class ProgressPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (Double, String)?
    private var scheduled = false

    func update(_ value: Double, status: String) {
        lock.lock()
        pending = (value, status)
        let needsSchedule = !scheduled
        if needsSchedule { scheduled = true }
        lock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.deliverOnMain(into: nil, completion: nil)
        }
    }

    @MainActor
    func flush(into appState: AppState) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.deliverOnMain(into: appState) {
                    continuation.resume()
                }
            }
        }
    }

    /// Must only be called from `DispatchQueue.main.async`.
    private func deliverOnMain(into appState: AppState?, completion: (() -> Void)?) {
        lock.lock()
        let next = pending
        pending = nil
        scheduled = false
        lock.unlock()

        if let next {
            MainActor.assumeIsolated {
                if let appState {
                    appState.scanProgress = next.0
                    appState.scanStatus = next.1
                } else if let shared = AppStateProgressTarget.current {
                    shared.scanProgress = next.0
                    shared.scanStatus = next.1
                }
            }
        }
        completion?()
    }

    /// Registers the active AppState so coalesced progress ticks (which don't
    /// carry an AppState reference) can still apply on the main queue.
    @MainActor
    func attach(_ appState: AppState) {
        AppStateProgressTarget.current = appState
    }

    @MainActor
    func detach() {
        AppStateProgressTarget.current = nil
    }
}

/// Weak box so progress callbacks scheduled without a strong AppState capture
/// can still publish onto the live view-model.
@MainActor
enum AppStateProgressTarget {
    static weak var current: AppState?
}

enum SortOrder: String, CaseIterable {
    case filename   = "Filename"
    case issueCount = "Issue Count"
    case artist     = "Artist"
    case album      = "Album"
}
