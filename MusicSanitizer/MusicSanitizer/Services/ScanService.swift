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
        progressHandler(0.01, "Listing audio files…")
        let urls = try collectAudioFiles(under: root) { count in
            // Keep the UI alive during large-folder walks (previously stayed on "Starting…").
            if count == 0 || count % 50 == 0 {
                progressHandler(0.02, "Listing audio files… \(count)")
            }
        }
        var files: [AudioFile] = []
        let total = Double(max(urls.count, 1))

        for (i, url) in urls.enumerated() {
            progressHandler(0.05 + 0.80 * (Double(i) / total), url.lastPathComponent)
            if let file = try? await buildAudioFile(url: url, root: root) {
                files.append(file)
            }
        }

        progressHandler(0.88, "Detecting duplicates…")
        var result = detectDuplicates(in: files)

        if settings.mergeSplitAlbums {
            progressHandler(0.94, "Looking for split albums…")
            result = detectSplitAlbums(in: result, root: root)
        }

        progressHandler(1.0, "Done")
        return result
    }

    // MARK: - File discovery

    private func collectAudioFiles(
        under root: URL,
        progress: ((Int) -> Void)? = nil
    ) throws -> [URL] {
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
                progress?(results.count)
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
            let inferred = Self.inferredTitle(fromFilename: file.url.deletingPathExtension().lastPathComponent)
            file.issues.append(FileIssue(
                kind: .missingTitle,
                description: "Title tag is empty",
                severity: .warning,
                autoFix: settings.fixMissingTitles || settings.lookupMetadata,
                proposedFix: inferred
            ))
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

    // MARK: - Split / deluxe album merge

    /// Finds albums split across folders with complementary track numbers
    /// (standard disc missing bonus tracks that live in a Deluxe folder, etc.)
    /// and proposes a single destination folder + canonical album name.
    private func detectSplitAlbums(in files: [AudioFile], root: URL) -> [AudioFile] {
        // Bucket by artist + normalized base album name.
        var buckets: [String: [Int]] = [:] // key → file indices
        for (index, file) in files.enumerated() {
            guard let track = file.tags.trackNumber else { continue }
            _ = track
            let artist = normalizedPerson(
                settings.preferAlbumArtist
                    ? (file.tags.albumArtist ?? file.tags.artist)
                    : (file.tags.artist ?? file.tags.albumArtist)
            )
            let album = file.tags.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let folderAlbum = file.url.deletingLastPathComponent().lastPathComponent
            let base = albumBaseName(album.isEmpty ? folderAlbum : album)
            guard !artist.isEmpty, !base.isEmpty else { continue }
            let key = artist + "\u{1f}" + base
            buckets[key, default: []].append(index)
        }

        var result = files

        for (_, indices) in buckets {
            guard indices.count >= 2 else { continue }

            // Group those files by containing folder.
            var byFolder: [String: [Int]] = [:]
            for i in indices {
                let folder = result[i].url.deletingLastPathComponent().path
                byFolder[folder, default: []].append(i)
            }
            guard byFolder.count >= 2 else { continue }

            let folderEntries: [(path: String, indices: [Int], tracks: Set<Int>)] = byFolder.map { path, idxs in
                let tracks = Set(idxs.compactMap { result[$0].tags.trackNumber })
                return (path, idxs, tracks)
            }

            // Pair complementary folders (low track overlap).
            var mergeSets: [[(path: String, indices: [Int], tracks: Set<Int>)]] = []
            var used = Set<String>()

            for i in 0..<folderEntries.count {
                let a = folderEntries[i]
                if used.contains(a.path) { continue }
                var cluster = [a]
                for j in (i + 1)..<folderEntries.count {
                    let b = folderEntries[j]
                    if used.contains(b.path) { continue }
                    if tracksAreComplementary(a.tracks, b.tracks)
                        || tracksAreComplementary(
                            cluster.reduce(into: Set<Int>()) { $0.formUnion($1.tracks) },
                            b.tracks
                        ) {
                        cluster.append(b)
                    }
                }
                if cluster.count >= 2 {
                    for item in cluster { used.insert(item.path) }
                    mergeSets.append(cluster)
                }
            }

            for cluster in mergeSets {
                let allIndices = cluster.flatMap(\.indices)
                let canonicalAlbum = chooseCanonicalAlbumName(
                    files: allIndices.map { result[$0] }
                )
                let artistForPath = (
                    settings.preferAlbumArtist
                        ? (result[allIndices[0]].tags.albumArtist ?? result[allIndices[0]].tags.artist)
                        : (result[allIndices[0]].tags.artist ?? result[allIndices[0]].tags.albumArtist)
                ) ?? "Unknown Artist"

                let folderComponents = settings.folderPattern.apply(
                    artist: artistForPath,
                    album: canonicalAlbum,
                    year: allIndices.compactMap { result[$0].tags.year }.min()
                )

                for i in allIndices {
                    let trackList = cluster.map { folder in
                        let sorted = folder.tracks.sorted()
                        let label = URL(fileURLWithPath: folder.path).lastPathComponent
                        return "\(label): \(sorted.map(String.init).joined(separator: ", "))"
                    }.joined(separator: " · ")

                    result[i].issues.append(FileIssue(
                        kind: .splitAlbum,
                        description: "Album split across folders with complementary tracks — merge as “\(canonicalAlbum)” (\(trackList))",
                        severity: .warning,
                        autoFix: true,
                        proposedFix: canonicalAlbum
                    ))

                    // Rebuild destination under the canonical album name.
                    let rawName = settings.filenamePattern.apply(
                        track: result[i].tags.trackNumber,
                        artist: result[i].tags.artist ?? result[i].tags.albumArtist,
                        title: result[i].tags.title
                    )
                    let safeName = sanitizeFilename(rawName)
                    let ext = result[i].url.pathExtension.lowercased()
                    var proposed = root
                    for component in folderComponents {
                        proposed = proposed.appendingPathComponent(sanitizeFilename(component))
                    }
                    proposed = proposed.appendingPathComponent("\(safeName).\(ext)")
                    result[i].proposedURL = proposed
                }
            }
        }

        return result
    }

    /// True when two track-number sets mostly fill each other's gaps
    /// (little overlap — e.g. {1–4,6–9} and {5,10–14}).
    private func tracksAreComplementary(_ a: Set<Int>, _ b: Set<Int>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let overlap = a.intersection(b).count
        let smaller = min(a.count, b.count)
        let unionCount = a.union(b).count
        // Allow a little accidental overlap, but require real complementary gain.
        let lowOverlap = Double(overlap) / Double(smaller) <= 0.25
        let fillsGaps = unionCount >= a.count + b.count - max(overlap, 0)
        let meaningful = unionCount > max(a.count, b.count)
        return lowOverlap && fillsGaps && meaningful
    }

    private func chooseCanonicalAlbumName(files: [AudioFile]) -> String {
        let names = files.compactMap { file -> String? in
            let tag = file.tags.album?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tag, !tag.isEmpty { return tag }
            let folder = file.url.deletingLastPathComponent().lastPathComponent
            return folder.isEmpty ? nil : folder
        }
        guard !names.isEmpty else { return "Unknown Album" }

        let scored = names.map { name -> (String, Int) in
            var score = name.count
            let lower = name.lowercased()
            if lower.contains("deluxe") { score += 100 }
            if lower.contains("expanded") { score += 80 }
            if lower.contains("complete") { score += 70 }
            if lower.contains("anniversary") { score += 60 }
            if lower.contains("special edition") { score += 50 }
            if lower.contains("remaster") { score += 20 }
            return (name, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? names[0]
    }

    private func albumBaseName(_ name: String) -> String {
        var s = name.lowercased()
        let junk: [String] = [
            "deluxe edition", "deluxe version", "the deluxe edition", "deluxe",
            "expanded edition", "expanded",
            "special edition", "bonus edition", "bonus tracks",
            "complete edition", "anniversary edition",
            "remastered", "remaster", "explicit",
        ]
        for phrase in junk.sorted(by: { $0.count > $1.count }) {
            for wrap in [" (\(phrase))", " [\(phrase)]", " - \(phrase)", " \(phrase)"] {
                s = s.replacingOccurrences(of: wrap, with: "")
            }
            if s.hasSuffix(phrase) {
                s = String(s.dropLast(phrase.count))
            }
        }
        // Drop leftover empty parens / brackets and collapse spaces.
        s = s.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[\s*\]"#, with: "", options: .regularExpression)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func normalizedPerson(_ name: String?) -> String {
        (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Hashes only the first and last 64 KB of a file.
    /// Fast enough for large libraries; still catches all practical duplicates.
    private func partialHash(url: URL) throws -> String {
        let chunkSize = 65_536  // 64 KB
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var hasher = SHA256()

        // First chunk
        let head = try fh.read(upToCount: chunkSize) ?? Data()
        hasher.update(data: head)

        // Last chunk (skip if file is smaller than 2 chunks)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if fileSize > chunkSize * 2 {
            try fh.seek(toOffset: UInt64(fileSize - chunkSize))
            let tail = try fh.read(upToCount: chunkSize) ?? Data()
            hasher.update(data: tail)
        }

        // Also mix in file size so a truncated copy doesn't collide
        withUnsafeBytes(of: Int64(fileSize).bigEndian) { hasher.update(bufferPointer: $0) }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort title from a filename like `01 - Artist - Title` or `01 - Title`.
    nonisolated static func inferredTitle(fromFilename name: String) -> String? {
        var remainder = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }

        if let match = remainder.range(
            of: #"^\d{1,3}\s*[-._)\]]\s*"#,
            options: .regularExpression
        ) {
            remainder = String(remainder[match.upperBound...])
        }

        let parts = remainder
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let title = parts.count >= 2 ? parts.last! : (parts.first ?? remainder)
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
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
