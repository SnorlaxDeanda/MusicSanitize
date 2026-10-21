import Foundation
import CryptoKit

// MARK: - Scan Service
// Walks a directory tree, reads tags, detects issues, proposes fixes.

actor ScanService {
    private let tagService = TagService()
    private let settings: ScanSettings

    init(settings: ScanSettings) {
        self.settings = settings
    }

    // MARK: - Main scan entry point

    func scan(root: URL, progressHandler: @Sendable @escaping (Double, String) -> Void) async throws -> [AudioFile] {
        let urls = try collectAudioFiles(under: root)
        var files: [AudioFile] = []
        let total = Double(urls.count)

        for (i, url) in urls.enumerated() {
            progressHandler(Double(i) / total, url.lastPathComponent)
            if let file = try? await buildAudioFile(url: url, root: root) {
                files.append(file)
            }
        }

        progressHandler(0.9, "Detecting duplicates…")
        let withDupes = detectDuplicates(in: files)

        progressHandler(1.0, "Done")
        return withDupes
    }

    // MARK: - File discovery

    private func collectAudioFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        let ext = settings.enabledFormats.flatMap { $0.fileExtensions }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            if ext.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - Build AudioFile with issues

    private func buildAudioFile(url: URL, root: URL) async throws -> AudioFile {
        let (tags, duration, fileSize) = try await tagService.readTags(from: url)
        let format = AudioFormat.from(extension: url.pathExtension)

        var file = AudioFile(url: url, tags: tags, format: format,
                             fileSize: fileSize, duration: duration)

        // Detect issues
        detectTagIssues(&file)
        detectFilenameIssues(&file)
        detectFolderIssues(&file, root: root)
        proposeNewURL(&file, root: root)

        return file
    }

    // MARK: - Issue detection

    private func detectTagIssues(_ file: inout AudioFile) {
        let t = file.tags
        if t.title?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            file.issues.append(FileIssue(kind: .missingTitle, description: "Title tag is empty",
                                         severity: .warning, autoFix: settings.lookupMetadata))
        }
        if t.artist?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            file.issues.append(FileIssue(kind: .missingArtist, description: "Artist tag is empty",
                                         severity: .warning, autoFix: settings.lookupMetadata))
        }
        if t.album?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            file.issues.append(FileIssue(kind: .missingAlbum, description: "Album tag is empty",
                                         severity: .info, autoFix: settings.lookupMetadata))
        }
        if t.year == nil {
            file.issues.append(FileIssue(kind: .missingYear, description: "Year tag is missing",
                                         severity: .info, autoFix: settings.lookupMetadata))
        }
        if t.trackNumber == nil {
            file.issues.append(FileIssue(kind: .missingTrackNumber, description: "Track number is missing",
                                         severity: .info, autoFix: false))
        }
        if !t.hasEmbeddedArtwork {
            file.issues.append(FileIssue(kind: .missingArtwork, description: "No embedded album artwork",
                                         severity: .info, autoFix: settings.fetchMissingArtwork))
        } else if let sz = t.artworkSize, sz > settings.maxArtworkKB * 1024 {
            let kb = sz / 1024
            file.issues.append(FileIssue(kind: .oversizedArtwork,
                                          description: "Embedded artwork is \(kb) KB (limit: \(settings.maxArtworkKB) KB)",
                                          severity: .warning, autoFix: settings.stripOversizedArtwork,
                                          proposedFix: "Strip oversized artwork"))
        }
    }

    private func detectFilenameIssues(_ file: inout AudioFile) {
        let name = file.url.deletingPathExtension().lastPathComponent
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")

        if name.unicodeScalars.contains(where: { illegal.contains($0) }) {
            file.issues.append(FileIssue(kind: .illegalFilenameChars,
                                          description: "Filename contains illegal characters",
                                          severity: .error, autoFix: true,
                                          proposedFix: sanitizeFilename(name)))
        }

        let proposed = settings.filenamePattern.apply(
            track: file.tags.trackNumber,
            artist: file.tags.artist ?? file.tags.albumArtist,
            title: file.tags.title
        )
        if proposed != name {
            file.issues.append(FileIssue(kind: .nonStandardNaming,
                                          description: "Filename doesn't match naming pattern",
                                          severity: .info, autoFix: true,
                                          proposedFix: proposed))
        }
    }

    private func detectFolderIssues(_ file: inout AudioFile, root: URL) {
        let artist = file.tags.albumArtist ?? file.tags.artist
        let expectedComponents = settings.folderPattern.apply(
            artist: artist,
            album: file.tags.album,
            year: file.tags.year
        )
        guard !expectedComponents.isEmpty else { return }

        let expectedRelative = expectedComponents.joined(separator: "/")
        let currentDir = file.url.deletingLastPathComponent().path
        let rootPath   = root.path

        if let range = currentDir.range(of: rootPath) {
            let relative = String(currentDir[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative != expectedRelative {
                file.issues.append(FileIssue(kind: .wrongFolder,
                                              description: "File is not in the expected folder",
                                              severity: .info, autoFix: true,
                                              proposedFix: expectedRelative))
            }
        }
    }

    // MARK: - Propose new URL

    private func proposeNewURL(_ file: inout AudioFile, root: URL) {
        guard file.hasIssues else { return }

        let artist = (file.tags.albumArtist ?? file.tags.artist) ?? "Unknown Artist"
        let folderComponents = settings.folderPattern.apply(
            artist: artist, album: file.tags.album, year: file.tags.year)

        let rawName = settings.filenamePattern.apply(
            track: file.tags.trackNumber,
            artist: file.tags.artist ?? file.tags.albumArtist,
            title: file.tags.title
        )
        let safeName = sanitizeFilename(rawName)
        let ext = file.url.pathExtension.lowercased()

        var proposed = root
        for component in folderComponents {
            proposed = proposed.appendingPathComponent(sanitizeFilename(component))
        }
        proposed = proposed.appendingPathComponent("\(safeName).\(ext)")
        file.proposedURL = proposed
    }

    // MARK: - Duplicate detection

    private func detectDuplicates(in files: [AudioFile]) -> [AudioFile] {
        guard settings.detectDuplicates else { return files }

        // Build keys — use cheap metadata-only keys first, partial hash only when needed
        var groups: [String: [UUID]] = [:]

        for file in files {
            let key: String
            switch settings.duplicateMethod {
            case .hashOnly:
                // Partial hash: first 64 KB + last 64 KB — fast, still reliable
                key = (try? partialHash(url: file.url)) ?? UUID().uuidString
            case .hashAndDuration:
                let hash = (try? partialHash(url: file.url)) ?? ""
                key = "\(hash)_\(Int(file.duration))"
            case .durationAndSize:
                // Pure metadata — zero disk I/O
                key = "\(Int(file.duration))_\(file.fileSize)"
            }
            groups[key, default: []].append(file.id)
        }

        let duplicateGroups = groups.filter { $0.value.count > 1 }
        let dupeIDs = Set(duplicateGroups.values.flatMap { $0 })

        // Build a lookup: id → groupKey for O(1) access
        var idToGroupKey: [UUID: String] = [:]
        for (key, ids) in duplicateGroups {
            for id in ids { idToGroupKey[id] = key }
        }

        // Stable group UUID derived from the key string
        var groupUUIDs: [String: UUID] = [:]

        var result = files
        for i in result.indices where dupeIDs.contains(result[i].id) {
            let key = idToGroupKey[result[i].id] ?? ""
            let gid = groupUUIDs[key, default: UUID()]
            groupUUIDs[key] = gid
            result[i].duplicateGroupID = gid
            result[i].issues.append(FileIssue(
                kind: .duplicate,
                description: "Possible duplicate — same \(settings.duplicateMethod.rawValue.lowercased())",
                severity: .warning,
                autoFix: false
            ))
        }
        return result
    }

    /// Hashes only the first and last 64 KB of a file.
    /// Fast enough for large libraries; still catches all practical duplicates.
    private func partialHash(url: URL) throws -> String {
        let chunkSize = 65_536  // 64 KB
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var hasher = SHA256()

        // First chunk
        let head = try fh.read(upToCount: chunkSize)
        hasher.update(data: head)

        // Last chunk (skip if file is smaller than 2 chunks)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if fileSize > chunkSize * 2 {
            try fh.seek(toOffset: UInt64(fileSize - chunkSize))
            let tail = try fh.read(upToCount: chunkSize)
            hasher.update(data: tail)
        }

        // Also mix in file size so a truncated copy doesn't collide
        withUnsafeBytes(of: Int64(fileSize).bigEndian) { hasher.update(bufferPointer: $0) }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Filename sanitization helper

    func sanitizeFilename(_ name: String) -> String {
        var result = name
        if settings.replaceUnderscores {
            result = result.replacingOccurrences(of: "_", with: " ")
        }
        // Remove illegal characters
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        result = result.unicodeScalars
            .filter { !illegal.contains($0) }
            .reduce("") { $0 + String($1) }
        // Collapse multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: .whitespaces)
        if settings.titleCaseNames {
            result = result.localizedCapitalized
        }
        return result
    }
}
