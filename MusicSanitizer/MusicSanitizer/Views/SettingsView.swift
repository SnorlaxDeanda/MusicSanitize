import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
            TagsSettingsTab()
                .tabItem { Label("Tags & Names", systemImage: "tag") }
            ArtworkSettingsTab()
                .tabItem { Label("Artwork", systemImage: "photo") }
            DuplicatesSettingsTab()
                .tabItem { Label("Duplicates", systemImage: "doc.on.doc") }
            WatchFolderSettingsTab()
                .tabItem { Label("Watch Folder", systemImage: "eye") }
        }
        .environmentObject(appState)
        .padding(20)
        .frame(width: 480, height: 420)
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    var s: ScanSettings { appState.settings }
    @State private var ffmpegStatus = TagService.ffmpegStatus()

    var body: some View {
        Form {
            Section("Backup") {
                Toggle("Back up originals before modifying", isOn: Binding(
                    get: { s.backupEnabled },
                    set: { s.backupEnabled = $0 }
                ))
                if s.backupEnabled {
                    TextField("Backup folder name", text: Binding(
                        get: { s.backupFolderName },
                        set: { s.backupFolderName = $0 }
                    ))
                }
            }
            Section("Formats to Process") {
                HStack {
                    Toggle("MP3",  isOn: Binding(get: { s.processMP3 },  set: { s.processMP3  = $0 }))
                    Toggle("FLAC", isOn: Binding(get: { s.processFLAC }, set: { s.processFLAC = $0 }))
                    Toggle("M4A",  isOn: Binding(get: { s.processM4A },  set: { s.processM4A  = $0 }))
                    Toggle("AIFF", isOn: Binding(get: { s.processAIFF }, set: { s.processAIFF = $0 }))
                    Toggle("WAV",  isOn: Binding(get: { s.processWAV },  set: { s.processWAV  = $0 }))
                }
            }
            Section("ffmpeg") {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: ffmpegStatus.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ffmpegStatus.isAvailable ? .green : .red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ffmpegStatus.isAvailable ? "Found" : "Not found")
                            .font(.body.weight(.medium))
                        Text(ffmpegStatus.displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !ffmpegStatus.isAvailable {
                            Text("Install with `brew install ffmpeg`, then ⌘Q and relaunch. Apple Silicon path: /opt/homebrew/bin/ffmpeg")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Recheck") {
                        ffmpegStatus = TagService.ffmpegStatus()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { ffmpegStatus = TagService.ffmpegStatus() }
    }
}

struct TagsSettingsTab: View {
    @EnvironmentObject var appState: AppState
    var s: ScanSettings { appState.settings }

    var body: some View {
        Form {
            Section("Filename Pattern") {
                Picker("Pattern", selection: Binding(
                    get: { s.filenamePattern },
                    set: { s.filenamePattern = $0 }
                )) {
                    ForEach(FilenamePattern.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                Toggle("Title case names", isOn: Binding(
                    get: { s.titleCaseNames },
                    set: { s.titleCaseNames = $0 }
                ))
                Toggle("Replace underscores with spaces", isOn: Binding(
                    get: { s.replaceUnderscores },
                    set: { s.replaceUnderscores = $0 }
                ))
            }
            Section("Folder Structure") {
                Picker("Organize into", selection: Binding(
                    get: { s.folderPattern },
                    set: { s.folderPattern = $0 }
                )) {
                    ForEach(FolderPattern.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                Toggle("Prefer Album Artist over Artist", isOn: Binding(
                    get: { s.preferAlbumArtist },
                    set: { s.preferAlbumArtist = $0 }
                ))
            }
            Section("MusicBrainz Lookup") {
                Toggle("Look up missing metadata online", isOn: Binding(
                    get: { s.lookupMetadata },
                    set: { s.lookupMetadata = $0 }
                ))
                if s.lookupMetadata {
                    HStack {
                        Text("Confidence threshold")
                        Slider(value: Binding(
                            get: { s.lookupConfidenceThreshold },
                            set: { s.lookupConfidenceThreshold = $0 }
                        ), in: 0.5...1.0, step: 0.05)
                        Text("\(Int(s.lookupConfidenceThreshold * 100))%")
                            .monospacedDigit()
                            .frame(width: 36)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ArtworkSettingsTab: View {
    @EnvironmentObject var appState: AppState
    var s: ScanSettings { appState.settings }

    var body: some View {
        Form {
            Section("Embedded Artwork") {
                Toggle("Fetch missing artwork from Cover Art Archive", isOn: Binding(
                    get: { s.fetchMissingArtwork },
                    set: { s.fetchMissingArtwork = $0 }
                ))
                Toggle("Strip oversized embedded artwork", isOn: Binding(
                    get: { s.stripOversizedArtwork },
                    set: { s.stripOversizedArtwork = $0 }
                ))
                if s.stripOversizedArtwork {
                    HStack {
                        Text("Maximum artwork size")
                        Slider(value: Binding(
                            get: { Double(s.maxArtworkKB) },
                            set: { s.maxArtworkKB = Int($0) }
                        ), in: 256...4096, step: 256)
                        Text("\(s.maxArtworkKB) KB")
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DuplicatesSettingsTab: View {
    @EnvironmentObject var appState: AppState
    var s: ScanSettings { appState.settings }

    var body: some View {
        Form {
            Section("Duplicate Detection") {
                Toggle("Detect duplicate files", isOn: Binding(
                    get: { s.detectDuplicates },
                    set: { s.detectDuplicates = $0 }
                ))
                if s.detectDuplicates {
                    Picker("Method", selection: Binding(
                        get: { s.duplicateMethod },
                        set: { s.duplicateMethod = $0 }
                    )) {
                        ForEach(DuplicateMethod.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    Text("Hash + Duration is accurate but slow for large libraries. Duration + Size is fast but may have false positives.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct WatchFolderSettingsTab: View {
    @EnvironmentObject var appState: AppState
    // Shared singleton — use ObservedObject, not StateObject (StateObject
    // must own its object's lifetime; wrapping a shared instance publishes
    // during view identity updates and trips the same SwiftUI warning).
    @ObservedObject private var watchState = WatchFolderState.shared

    var body: some View {
        Form {
            Section("Watch Folder") {
                Toggle("Enable Watch Folder mode", isOn: $watchState.isEnabled)
                    .onChange(of: watchState.isEnabled) { enabled in
                        // Start/stop publishes watcher state; defer so the
                        // Toggle's own view update can finish first.
                        DispatchQueue.main.async {
                            if enabled, let url = watchState.watchURL {
                                watchState.start(url: url, settings: appState.settings)
                            } else {
                                watchState.stop()
                            }
                        }
                    }

                if watchState.isEnabled || watchState.watchURL != nil {
                    HStack {
                        Text(watchState.watchURL?.path ?? "No folder selected")
                            .font(.callout)
                            .foregroundStyle(watchState.watchURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            watchState.chooseFolder(settings: appState.settings)
                        }
                    }
                }

                if watchState.isEnabled {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Watching for new files…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if watchState.processedCount > 0 {
                        Text("Processed \(watchState.processedCount) file\(watchState.processedCount == 1 ? "" : "s") this session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Auto-Fix Options") {
                Toggle("Automatically apply fixes to new files", isOn: $watchState.autoFix)
                Toggle("Send notification when files are processed", isOn: $watchState.sendNotifications)
            }
        }
        .formStyle(.grouped)
    }
}
