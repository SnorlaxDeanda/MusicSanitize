import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 200)
        } content: {
            FileListView()
                .frame(minWidth: 400)
        } detail: {
            if let file = appState.selectedFile {
                FileDetailView(file: file)
            } else {
                EmptyDetailView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { appState.requestFolderSelection() }) {
                    Label("Open Folder", systemImage: "folder")
                }
                if let root = appState.scanRoot {
                    Text(root.lastPathComponent)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if appState.isScanning || appState.isApplying {
                    ProgressView(value: appState.scanProgress)
                        .frame(width: 120)
                    Text(appState.scanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Button(action: { Task { await appState.scan() } }) {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .disabled(appState.scanRoot == nil)
                    .keyboardShortcut("r")

                    Button(action: { appState.showDiffSheet = true }) {
                        Label("Preview Fixes", systemImage: "doc.badge.clock")
                    }
                    .disabled(appState.files.isEmpty || !appState.files.contains { $0.hasIssues })

                    Button(action: { Task { await appState.applyFixes() } }) {
                        Label("Apply Fixes", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(appState.files.isEmpty || appState.selectedCount == 0)
                    .tint(.green)
                }
            }
        }
        .sheet(isPresented: $appState.showDiffSheet) {
            DiffPreviewSheet()
                .environmentObject(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
        .sheet(isPresented: $appState.showReportSheet) {
            ReportSheet()
                .environmentObject(appState)
                .frame(minWidth: 500, minHeight: 400)
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}

// MARK: - Empty state

struct EmptyDetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            if appState.scanRoot == nil {
                Image(systemName: "music.note.house")
                    .font(.system(size: 64))
                    .foregroundStyle(.tertiary)
                Text("Open a Music Folder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Choose a folder to scan your library for issues.")
                    .foregroundStyle(.tertiary)
                Button("Open Folder…") {
                    appState.requestFolderSelection()
                }
                .buttonStyle(.borderedProminent)
            } else if appState.files.isEmpty && !appState.isScanning {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 64))
                    .foregroundStyle(.tertiary)
                Text("Ready to Scan")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Press ⌘R to scan \(appState.scanRoot!.lastPathComponent)")
                    .foregroundStyle(.tertiary)
                Button("Scan Now") {
                    Task { await appState.scan() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "arrow.left")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Select a file to see details")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
