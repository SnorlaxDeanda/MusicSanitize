import Foundation
import AVFoundation
import AppKit

// MARK: - Audio File Model

struct AudioFile: Identifiable, Hashable {
    static func == (lhs: AudioFile, rhs: AudioFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID
    let url: URL
    var tags: AudioTags
    var issues: [FileIssue]
    var proposedURL: URL?
    var duplicateGroupID: UUID?
    var fileSize: Int64
    var duration: TimeInterval
    var format: AudioFormat
    var isSelected: Bool

    init(url: URL, tags: AudioTags, format: AudioFormat, fileSize: Int64, duration: TimeInterval) {
        self.id = UUID()
        self.url = url
        self.tags = tags
        self.issues = []
        self.proposedURL = nil
        self.duplicateGroupID = nil
        self.fileSize = fileSize
        self.duration = duration
        self.format = format
        self.isSelected = true
    }

    var filename: String { url.lastPathComponent }
    var hasIssues: Bool { !issues.isEmpty }
    var issueCount: Int { issues.count }

    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

// MARK: - Audio Tags

struct AudioTags: Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var comment: String?
    var hasEmbeddedArtwork: Bool
    var artworkSize: Int?          // bytes if embedded
    var composer: String?
    var lyrics: String?

    static var empty: AudioTags {
        AudioTags(title: nil, artist: nil, albumArtist: nil, album: nil,
                  genre: nil, year: nil, trackNumber: nil, trackTotal: nil,
                  discNumber: nil, discTotal: nil, comment: nil,
                  hasEmbeddedArtwork: false, artworkSize: nil,
                  composer: nil, lyrics: nil)
    }
}

// MARK: - Audio Format

enum AudioFormat: String, CaseIterable {
    case mp3  = "MP3"
    case flac = "FLAC"
    case m4a  = "M4A/AAC"
    case aiff = "AIFF"
    case wav  = "WAV"
    case ogg  = "OGG"
    case wma  = "WMA"
    case unknown = "Unknown"

    var fileExtensions: [String] {
        switch self {
        case .mp3:  return ["mp3"]
        case .flac: return ["flac"]
        case .m4a:  return ["m4a", "aac", "mp4"]
        case .aiff: return ["aiff", "aif"]
        case .wav:  return ["wav"]
        case .ogg:  return ["ogg", "oga"]
        case .wma:  return ["wma"]
        case .unknown: return []
        }
    }

    static func from(extension ext: String) -> AudioFormat {
        let lower = ext.lowercased()
        return allCases.first { $0.fileExtensions.contains(lower) } ?? .unknown
    }
}

// MARK: - File Issues

enum IssueKind: String, CaseIterable {
    case missingTitle        = "Missing Title"
    case missingArtist       = "Missing Artist"
    case missingAlbum        = "Missing Album"
    case missingYear         = "Missing Year"
    case missingTrackNumber  = "Missing Track Number"
    case missingArtwork      = "Missing Artwork"
    case oversizedArtwork    = "Oversized Artwork"
    case illegalFilenameChars = "Illegal Filename Characters"
    case nonStandardNaming   = "Non-standard Filename"
    case wrongFolder         = "Wrong Folder Location"
    case duplicate           = "Possible Duplicate"
    case extensionMismatch   = "Extension Mismatch"
    case malformedTag        = "Malformed Tag"
}

struct FileIssue: Identifiable, Hashable {
    static func == (lhs: FileIssue, rhs: FileIssue) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID
    let kind: IssueKind
    let description: String
    let severity: IssueSeverity
    var autoFix: Bool      // can be fixed automatically
    var proposedFix: String?

    init(kind: IssueKind, description: String, severity: IssueSeverity = .warning,
         autoFix: Bool = true, proposedFix: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.description = description
        self.severity = severity
        self.autoFix = autoFix
        self.proposedFix = proposedFix
    }
}

enum IssueSeverity: String, Comparable {
    case info    = "Info"
    case warning = "Warning"
    case error   = "Error"

    static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool {
        let order: [IssueSeverity] = [.info, .warning, .error]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }

    var color: String {
        switch self {
        case .info:    return "blue"
        case .warning: return "yellow"
        case .error:   return "red"
        }
    }
}
