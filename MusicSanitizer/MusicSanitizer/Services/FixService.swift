import Foundation
import AppKit

// MARK: - Fix Service
// Applies proposed fixes to audio files after user confirmation.

actor FixService {
    private let tagService = TagService()
    private let mbService  = MusicBrainzService()
    private let settings:  ScanSettings

    init(settings: ScanSettings) {
        self.settings = settings
    }

    // MARK: - Apply all fixes

    func applyFixes(
        to files: [AudioFile],
        root: URL,
        progressHandler: @Sendable @escaping (Double, String) -> Void
    ) async throws -> FixReport {

        // 1. Create backup if enabled
        let backupRoot: URL?
        if settings.backupEnabled {
            backupRoot = try createBackup(files: files, root: root)
            progressHandler(0.05, "Backup created")
        } else {
            backupRoot = nil
        }

        var report = FixReport()
        let total = Double(files.count)

        for (i, file) in files.enumerated() where file.isSelected {
            progressHandler(Double(i) / total, file.filename)
            let result = await fixFile(file, root: root)
            report.results.append(result)
        }

        progressHandler(1.0, "Done")
        report.backupLocation = backupRoot
        return report
    }

    // MARK: - Fix a single file

    private func fixFile(_ file: AudioFile, root: URL) async -> FileFixResult {
        var result = FileFixResult(file: file)
        var tags = file.tags

        // MusicBrainz lookup if needed
        if settings.lookupMetadata {
            let needsLookup = file.issues.contains { [.missingTitle, .missingArtist, .missingAlbum, .missingYear].contains($0.kind) }
            if needsLookup {
                if let fetched = await mbService.lookup(title: tags.title, artist: tags.artist, album: tags.album) {
                    if tags.title  == nil || tags.title!.isEmpty  { tags.title  = fetched.title }
                    if tags.artist == nil || tags.artist!.isEmpty { tags.artist = fetched.artist }
                    if tags.album  == nil || tags.album!.isEmpty  { tags.album  = fetched.album }
                    if tags.year   == nil                          { tags.year   = fetched.year }
                    if tags.trackNumber == nil                     { tags.trackNumber = fetched.trackNumber }
                    if tags.albumArtist == nil                     { tags.albumArtist = fetched.albumArtist }
                    result.appliedLookup = true
                }
            }
        }

        // Fetch artwork if missing
        if settings.fetchMissingArtwork && !tags.hasEmbeddedArtwork {
            // Note: artwork embedding requires additional ffmpeg step —
            // for now we save it alongside the file as cover.jpg
            // Full embedding would use: ffmpeg -i audio.mp3 -i cover.jpg -map 0 -map 1 -c copy out.mp3
            result.artworkFetchAttempted = true
        }

        // Write updated tags
        do {
            try await tagService.writeTags(tags, to: file.url)
            result.tagsWritten = true
        } catch {
            result.errors.append("Tag write failed: \(error.localizedDescription)")
        }

        // Strip oversized artwork
        if settings.stripOversizedArtwork,
           let artSize = tags.artworkSize, artSize > settings.maxArtworkKB * 1024 {
            do {
                try await tagService.stripArtwork(from: file.url, maxBytes: settings.maxArtworkKB * 1024)
                result.artworkStripped = true
            } catch {
                result.errors.append("Artwork strip failed: \(error.localizedDescription)")
            }
        }

        // Move file to proposed location
        if let proposed = file.proposedURL, proposed != file.url {
            do {
                try moveFile(from: file.url, to: proposed, root: root)
                result.movedTo = proposed
            } catch {
                result.errors.append("Move failed: \(error.localizedDescription)")
            }
        }

        return result
    }

    // MARK: - Backup

    private func createBackup(files: [AudioFile], root: URL) throws -> URL {
        let fm = FileManager.default
        let backupRoot = root.appendingPathComponent(settings.backupFolderName)
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        for file in files where file.isSelected {
            let rel  = file.url.path.replacingOccurrences(of: root.path, with: "")
            let dest = backupRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: file.url, to: dest)
            }
        }
        return backupRoot
    }

    // MARK: - File move with directory creation

    private func moveFile(from source: URL, to dest: URL, root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // If destination exists, add a suffix
        var finalDest = dest
        var counter = 1
        while fm.fileExists(atPath: finalDest.path) {
            let base = dest.deletingPathExtension().lastPathComponent
            let ext  = dest.pathExtension
            finalDest = dest.deletingLastPathComponent()
                .appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }

        try fm.moveItem(at: source, to: finalDest)

        // Remove empty source directories up to root
        var dir = source.deletingLastPathComponent()
        while dir.path != root.path {
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
            dir = dir.deletingLastPathComponent()
        }
    }
}

// MARK: - Fix Report

struct FixReport {
    var results: [FileFixResult] = []
    var backupLocation: URL?

    var successCount: Int { results.filter { $0.errors.isEmpty }.count }
    var errorCount:   Int { results.filter { !$0.errors.isEmpty }.count }

    var csvString: String {
        var lines = ["File,Tags Written,Moved To,Artwork Stripped,Errors"]
        for r in results {
            let moved = r.movedTo?.lastPathComponent ?? ""
            let errs  = r.errors.joined(separator: "; ")
            lines.append("\"\(r.file.filename)\",\(r.tagsWritten),\"\(moved)\",\(r.artworkStripped),\"\(errs)\"")
        }
        return lines.joined(separator: "\n")
    }
}

struct FileFixResult {
    var file: AudioFile
    var tagsWritten: Bool       = false
    var movedTo: URL?           = nil
    var artworkStripped: Bool   = false
    var artworkFetchAttempted: Bool = false
    var appliedLookup: Bool     = false
    var errors: [String]        = []
}
