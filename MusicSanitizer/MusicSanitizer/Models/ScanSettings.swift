import Foundation

// MARK: - Scan & Fix Settings (persisted via UserDefaults)

class ScanSettings: ObservableObject {
    // File handling
    @Published var backupEnabled: Bool = true
    @Published var backupFolderName: String = "_MusicSanitizer_Backup"

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

    var enabledFormats: [AudioFormat] {
        var formats: [AudioFormat] = []
        if processMP3  { formats.append(.mp3) }
        if processFLAC { formats.append(.flac) }
        if processM4A  { formats.append(.m4a) }
        if processAIFF { formats.append(.aiff) }
        if processWAV  { formats.append(.wav) }
        return formats
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
