import Foundation

// MARK: - Scan & Fix Settings (backup prefs persisted via UserDefaults)

class ScanSettings: ObservableObject {
    private enum Keys {
        static let backupEnabled    = "ms.backupEnabled"
        static let backupFolderName = "ms.backupFolderName"
        static let backupMode       = "ms.backupMode"
        static let backupBookmark   = "ms.backupCustomBookmark"
    }

    // File handling
    @Published var backupEnabled: Bool {
        didSet { UserDefaults.standard.set(backupEnabled, forKey: Keys.backupEnabled) }
    }
    @Published var backupFolderName: String {
        didSet { UserDefaults.standard.set(backupFolderName, forKey: Keys.backupFolderName) }
    }
    /// Where to put the backup folder.
    @Published var backupMode: BackupMode {
        didSet { UserDefaults.standard.set(backupMode.rawValue, forKey: Keys.backupMode) }
    }
    /// Absolute URL chosen by the user when backupMode == .customFolder.
    @Published var backupCustomURL: URL? {
        didSet { persistCustomBackupURL(backupCustomURL) }
    }

    // Naming pattern
    @Published var filenamePattern: FilenamePattern = .trackArtistTitle
    @Published var folderPattern: FolderPattern = .artistAlbum
    @Published var preferAlbumArtist: Bool = true
    @Published var titleCaseNames: Bool = true
    @Published var replaceUnderscores: Bool = true

    // Tags to fix
    @Published var fixMissingTitles: Bool = true
    @Published var fixMissingArtists: Bool = true
    @Published var fixMissingAlbums: Bool = true
    @Published var fixMissingYear: Bool = true
    @Published var fixMissingTrackNumbers: Bool = true

    // Artwork
    @Published var stripOversizedArtwork: Bool = true
    @Published var maxArtworkKB: Int = 1024          // 1 MB
    @Published var fetchMissingArtwork: Bool = true

    // MusicBrainz lookup
    @Published var lookupMetadata: Bool = true
    @Published var lookupConfidenceThreshold: Double = 0.85

    // Duplicate detection
    @Published var detectDuplicates: Bool = true
    @Published var duplicateMethod: DuplicateMethod = .hashAndDuration

    // Formats to process
    @Published var processMP3: Bool  = true
    @Published var processFLAC: Bool = true
    @Published var processM4A: Bool  = true
    @Published var processAIFF: Bool = false
    @Published var processWAV: Bool  = false

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.backupEnabled) == nil {
            backupEnabled = true
        } else {
            backupEnabled = defaults.bool(forKey: Keys.backupEnabled)
        }
        backupFolderName = defaults.string(forKey: Keys.backupFolderName) ?? "_MusicSanitizer_Backup"
        if let raw = defaults.string(forKey: Keys.backupMode),
           let mode = BackupMode(rawValue: raw) {
            backupMode = mode
        } else {
            backupMode = .insideSourceFolder
        }
        backupCustomURL = Self.resolveCustomBackupURL()
    }

    var enabledFormats: [AudioFormat] {
        var formats: [AudioFormat] = []
        if processMP3  { formats.append(.mp3) }
        if processFLAC { formats.append(.flac) }
        if processM4A  { formats.append(.m4a) }
        if processAIFF { formats.append(.aiff) }
        if processWAV  { formats.append(.wav) }
        return formats
    }

    /// Caption for preview/report UI.
    var backupDestinationDescription: String {
        guard backupEnabled else { return "Backup disabled" }
        switch backupMode {
        case .insideSourceFolder:
            return "\(backupFolderName)/ inside the music folder"
        case .customFolder:
            if let url = backupCustomURL {
                return "Custom folder: \(url.path)"
            }
            return "Custom folder (none chosen yet)"
        }
    }

    var isBackupConfigurationValid: Bool {
        guard backupEnabled else { return true }
        switch backupMode {
        case .insideSourceFolder:
            return !backupFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .customFolder:
            return backupCustomURL != nil
        }
    }

    private func persistCustomBackupURL(_ url: URL?) {
        let defaults = UserDefaults.standard
        guard let url else {
            defaults.removeObject(forKey: Keys.backupBookmark)
            return
        }
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Keys.backupBookmark)
        } catch {
            // Fall back to plain path string if bookmarking fails (unsigned / no sandbox).
            defaults.set(url.path, forKey: Keys.backupBookmark)
        }
    }

    private static func resolveCustomBackupURL() -> URL? {
        let defaults = UserDefaults.standard
        guard let stored = defaults.object(forKey: Keys.backupBookmark) else { return nil }

        if let data = stored as? Data {
            var isStale = false
            let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if let url {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }

        if let path = stored as? String {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

enum FilenamePattern: String, CaseIterable, Identifiable {
    case trackArtistTitle  = "01 - Artist - Title"
    case trackTitle        = "01 - Title"
    case artistTitle       = "Artist - Title"
    case titleOnly         = "Title"

    var id: String { rawValue }

    func apply(track: Int?, artist: String?, title: String?) -> String {
        let t  = title  ?? "Unknown Title"
        let a  = artist ?? "Unknown Artist"
        let tr = track.map { String(format: "%02d", $0) } ?? "00"
        switch self {
        case .trackArtistTitle: return "\(tr) - \(a) - \(t)"
        case .trackTitle:       return "\(tr) - \(t)"
        case .artistTitle:      return "\(a) - \(t)"
        case .titleOnly:        return t
        }
    }
}

enum FolderPattern: String, CaseIterable, Identifiable {
    case artistAlbum      = "Artist/Album"
    case artistAlbumYear  = "Artist/Year - Album"
    case flat             = "Flat (no subfolders)"

    var id: String { rawValue }

    func apply(artist: String?, album: String?, year: Int?) -> [String] {
        let a = artist ?? "Unknown Artist"
        let b = album  ?? "Unknown Album"
        switch self {
        case .artistAlbum:
            return [a, b]
        case .artistAlbumYear:
            let y = year.map { "\($0) - " } ?? ""
            return [a, "\(y)\(b)"]
        case .flat:
            return []
        }
    }
}

enum DuplicateMethod: String, CaseIterable, Identifiable {
    case hashOnly         = "File Hash Only"
    case hashAndDuration  = "Hash + Duration"
    case durationAndSize  = "Duration + File Size"

    var id: String { rawValue }
}

// MARK: - Backup destination mode

enum BackupMode: String, CaseIterable, Identifiable {
    case insideSourceFolder = "Inside source folder"
    case customFolder       = "Custom folder…"

    var id: String { rawValue }
}
