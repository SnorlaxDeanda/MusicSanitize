import Foundation
import AVFoundation
import AppKit

// MARK: - Tag Reading & Writing Service
// Reading:  AVFoundation first; falls back to ffprobe (ships with ffmpeg) on any
//           error or when AVFoundation returns empty tags, e.g. malformed ID3 frames
//           that log "FMDR_ID3 signalled err=-12609".
// Writing:  Always delegates to ffmpeg for reliable cross-format support.

actor TagService {

    // MARK: - Read tags from a file URL

    func readTags(from url: URL) async throws -> (tags: AudioTags, duration: TimeInterval, fileSize: Int64) {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0

        // Try AVFoundation first
        if let avResult = try? await readTagsAVFoundation(from: url) {
            // Fall back to ffprobe if AVFoundation returned mostly empty tags
            // (title, artist and album all nil is a strong sign it failed silently)
            let t = avResult.tags
            let isEmpty = t.title == nil && t.artist == nil && t.album == nil
            if !isEmpty {
                return (t, avResult.duration, fileSize)
            }
        }

        // ffprobe fallback
        let ffprobeResult = try await readTagsFFprobe(from: url)
        return (ffprobeResult.tags, ffprobeResult.duration, fileSize)
    }

    // MARK: - AVFoundation reader

    private func readTagsAVFoundation(from url: URL) async throws -> (tags: AudioTags, duration: TimeInterval) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        async let avMeta     = asset.loadMetadata(for: .id3Metadata)
        async let iTunesMeta = asset.loadMetadata(for: .iTunesMetadata)
        async let commonMeta = asset.load(.commonMetadata)
        async let duration   = asset.load(.duration)

        let (id3, itunes, common, dur) = try await (avMeta, iTunesMeta, commonMeta, duration)
        let allMeta = id3 + itunes + common

        var tags = AudioTags.empty
        tags.title       = stringValue(from: allMeta, key: .commonKeyTitle)
                        ?? stringValue(from: allMeta, identifier: .iTunesMetadataSongName)
        tags.artist      = stringValue(from: allMeta, key: .commonKeyArtist)
                        ?? stringValue(from: allMeta, identifier: .iTunesMetadataArtist)
        tags.albumArtist = stringValue(from: allMeta, identifier: .iTunesMetadataAlbumArtist)
                        ?? stringValue(from: allMeta, id3Key: "TPE2")
        tags.album       = stringValue(from: allMeta, key: .commonKeyAlbumName)
        tags.genre       = stringValue(from: allMeta, key: .commonKeyType)
                        ?? stringValue(from: allMeta, identifier: .iTunesMetadataUserGenre)
        tags.composer    = stringValue(from: allMeta, key: .commonKeyCreator)

        // Year
        let yearStr = stringValue(from: allMeta, id3Key: "TDRC")
                   ?? stringValue(from: allMeta, id3Key: "TYER")
                   ?? stringValue(from: allMeta, identifier: .iTunesMetadataReleaseDate)
        tags.year = yearStr.flatMap { Int($0.prefix(4)) }

        // Track number
        let trackStr = stringValue(from: allMeta, id3Key: "TRCK")
                    ?? stringValue(from: allMeta, identifier: .iTunesMetadataTrackNumber)
        if let t = trackStr {
            let parts = t.split(separator: "/")
            tags.trackNumber = Int(parts[0].trimmingCharacters(in: .whitespaces))
            if parts.count > 1 { tags.trackTotal = Int(parts[1].trimmingCharacters(in: .whitespaces)) }
        }

        // Artwork
        let artItems = allMeta.filter {
            $0.commonKey == .commonKeyArtwork ||
            $0.identifier == .iTunesMetadataCoverArt ||
            $0.identifier == .id3MetadataAttachedPicture
        }
        if let artItem = artItems.first, let data = try? await artItem.load(.dataValue) {
            tags.hasEmbeddedArtwork = true
            tags.artworkSize = data.count
        }

        return (tags, dur.seconds)
    }

    // MARK: - ffprobe fallback reader

    private func readTagsFFprobe(from url: URL) async throws -> (tags: AudioTags, duration: TimeInterval) {
        let ffprobe = try Self.ffprobePath()

        let args = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]

        let result = try await runProcess(ffprobe, args: args)
        guard result.exitCode == 0, !result.stdout.isEmpty else {
            throw TagError.ffprobeFailed(result.stderr)
        }

        return try parseFFprobeJSON(result.stdout)
    }

    private func parseFFprobeJSON(_ json: String) throws -> (tags: AudioTags, duration: TimeInterval) {
        guard let data = json.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw TagError.ffprobeFailed("Invalid JSON") }

        let format = obj["format"] as? [String: Any]
        let tags   = (format?["tags"] as? [String: Any]) ?? [:]

        // ffprobe tag keys are lowercase
        func tag(_ keys: String...) -> String? {
            keys.lazy.compactMap { tags[$0] as? String ?? tags[$0.uppercased()] as? String }.first
        }

        var audioTags = AudioTags.empty
        audioTags.title       = tag("title")
        audioTags.artist      = tag("artist")
        audioTags.albumArtist = tag("album_artist", "albumartist")
        audioTags.album       = tag("album")
        audioTags.genre       = tag("genre")
        audioTags.composer    = tag("composer")
        audioTags.year        = tag("date", "year").flatMap { Int($0.prefix(4)) }

        if let track = tag("track") {
            let parts = track.split(separator: "/")
            audioTags.trackNumber = Int(parts[0].trimmingCharacters(in: .whitespaces))
            if parts.count > 1 { audioTags.trackTotal = Int(parts[1].trimmingCharacters(in: .whitespaces)) }
        }

        // Duration from format
        let durationSecs: TimeInterval
        if let durStr = format?["duration"] as? String, let d = Double(durStr) {
            durationSecs = d
        } else {
            // Try first audio stream
            let streams = obj["streams"] as? [[String: Any]] ?? []
            let audioStream = streams.first { $0["codec_type"] as? String == "audio" }
            let durStr = audioStream?["duration"] as? String ?? "0"
            durationSecs = Double(durStr) ?? 0
        }

        // Check for embedded artwork in streams
        let streams = obj["streams"] as? [[String: Any]] ?? []
        let hasArt = streams.contains { stream in
            let codecType = stream["codec_type"] as? String
            let disposition = stream["disposition"] as? [String: Any]
            return codecType == "video" && (disposition?["attached_pic"] as? Int == 1)
        }
        audioTags.hasEmbeddedArtwork = hasArt

        return (audioTags, durationSecs)
    }

    // MARK: - Write tags using ffmpeg

    func writeTags(_ tags: AudioTags, to url: URL) async throws {
        let ffmpeg = try Self.ffmpegPath()
        let tmp = url.deletingLastPathComponent().appendingPathComponent("._tmp_\(url.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var args: [String] = [
            "-y", "-i", url.path,
            "-c", "copy",
            "-map_metadata", "0"
        ]

        if let v = tags.title       { args += ["-metadata", "title=\(v)"] }
        if let v = tags.artist      { args += ["-metadata", "artist=\(v)"] }
        if let v = tags.albumArtist { args += ["-metadata", "album_artist=\(v)"] }
        if let v = tags.album       { args += ["-metadata", "album=\(v)"] }
        if let v = tags.genre       { args += ["-metadata", "genre=\(v)"] }
        if let v = tags.year        { args += ["-metadata", "date=\(v)"] }
        if let v = tags.trackNumber {
            let s = tags.trackTotal.map { "\(v)/\($0)" } ?? "\(v)"
            args += ["-metadata", "track=\(s)"]
        }
        if let v = tags.composer    { args += ["-metadata", "composer=\(v)"] }

        args.append(tmp.path)

        let result = try await runProcess(ffmpeg, args: args)
        if result.exitCode != 0 { throw TagError.ffmpegFailed(result.stderr) }

        try FileManager.default.replaceItem(at: url, withItemAt: tmp,
                                            backupItemName: nil,
                                            options: .usingNewMetadataOnly,
                                            resultingItemURL: nil)
    }

    // MARK: - Strip oversized artwork

    func stripArtwork(from url: URL, maxBytes: Int) async throws {
        let (tags, _, _) = try await readTags(from: url)
        guard let size = tags.artworkSize, size > maxBytes else { return }

        let ffmpeg = try Self.ffmpegPath()
        let tmp = url.deletingLastPathComponent().appendingPathComponent("._noart_\(url.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let args: [String] = ["-y", "-i", url.path, "-c", "copy",
                              "-map_metadata", "0", "-vn", tmp.path]
        let result = try await runProcess(ffmpeg, args: args)
        if result.exitCode != 0 { throw TagError.ffmpegFailed(result.stderr) }

        try FileManager.default.replaceItem(at: url, withItemAt: tmp,
                                            backupItemName: nil,
                                            options: .usingNewMetadataOnly,
                                            resultingItemURL: nil)
    }

    // MARK: - Tool paths

    static func ffmpegPath() throws -> String {
        if let cached = ToolPathCache.ffmpeg,
           FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        let path = try resolveTool(named: "ffmpeg")
        ToolPathCache.ffmpeg = path
        return path
    }

    static func ffprobePath() throws -> String {
        if let cached = ToolPathCache.ffprobe,
           FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        // Prefer a real ffprobe; fall back to ffmpeg if needed.
        if let path = try? resolveTool(named: "ffprobe") {
            ToolPathCache.ffprobe = path
            return path
        }
        return try ffmpegPath()
    }

    /// Locates an ffmpeg-family binary: bundled copy, common Homebrew paths,
    /// then the user's login-shell PATH (so Apple Silicon Homebrew is found).
    private static func resolveTool(named name: String) throws -> String {
        var candidates: [String] = []

        if let bundled = Bundle.main.path(forResource: name, ofType: nil) {
            candidates.append(bundled)
        }
        if let fromShell = resolveViaLoginShell(name) {
            candidates.append(fromShell)
        }
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]

        // Deduplicate while preserving order
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            // Homebrew symlinks can look non-executable to isExecutableFile
            // when the target is fine — resolve and re-check.
            if let resolved = resolveSymlinks(path),
               resolved != path,
               FileManager.default.isExecutableFile(atPath: resolved) {
                return resolved
            }
        }
        throw TagError.ffmpegNotFound
    }

    private static func resolveSymlinks(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath().path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
    }

    /// Asks the login shell where a tool lives — picks up Homebrew on PATH
    /// even when the GUI app's environment is minimal.
    private static func resolveViaLoginShell(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty else { return nil }
            return path
        } catch {
            return nil
        }
    }

    // MARK: - Metadata helpers

    private func stringValue(from items: [AVMetadataItem], key: AVMetadataKey) -> String? {
        cleaned(items.first { $0.commonKey == key }?.stringValue)
    }

    private func stringValue(from items: [AVMetadataItem], identifier: AVMetadataIdentifier) -> String? {
        cleaned(items.first { $0.identifier == identifier }?.stringValue)
    }

    private func stringValue(from items: [AVMetadataItem], id3Key: String) -> String? {
        if let identifier = AVMetadataItem.identifier(forKey: id3Key as NSString, keySpace: .id3),
           let value = stringValue(from: items, identifier: identifier) {
            return value
        }
        return cleaned(items.first { ($0.key as? String) == id3Key }?.stringValue)
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Process runner

    private func runProcess(_ path: String, args: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError  = errPipe
            proc.terminationHandler = { p in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (p.terminationStatus, out, err))
            }
            do { try proc.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}

// MARK: - Errors

enum TagError: LocalizedError {
    case ffmpegNotFound
    case ffmpegFailed(String)
    case ffprobeFailed(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg not found. Install via Homebrew (`brew install ffmpeg`), then fully quit and relaunch Music Sanitizer so it can see /opt/homebrew/bin/ffmpeg."
        case .ffmpegFailed(let msg):
            return "ffmpeg error: \(msg)"
        case .ffprobeFailed(let msg):
            return "ffprobe error: \(msg)"
        case .unsupportedFormat:
            return "Unsupported audio format"
        }
    }
}

