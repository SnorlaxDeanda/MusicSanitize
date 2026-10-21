import Foundation

// MARK: - MusicBrainz Metadata Lookup
// Uses the MusicBrainz API (no key required) to fill missing tags.

actor MusicBrainzService {

    private let baseURL = "https://musicbrainz.org/ws/2"
    private let userAgent = "MusicSanitizer/1.0 (https://github.com/yourusername/MusicSanitizer)"
    private var lastRequestTime: Date = .distantPast

    // Rate limit: MusicBrainz allows 1 req/sec for anonymous users
    private let minInterval: TimeInterval = 1.1

    // MARK: - Lookup by title + artist

    func lookup(title: String?, artist: String?, album: String?) async -> AudioTags? {
        guard let title = title, !title.isEmpty else { return nil }

        await rateLimit()

        var query = "recording:\"\(title)\""
        if let a = artist, !a.isEmpty { query += " AND artist:\"\(a)\"" }
        if let b = album,  !b.isEmpty { query += " AND release:\"\(b)\"" }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr  = "\(baseURL)/recording?query=\(encoded)&fmt=json&limit=5"

        guard let url = URL(string: urlStr) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try parseLookupResponse(data: data, targetTitle: title, targetArtist: artist)
        } catch {
            return nil
        }
    }

    // MARK: - Lookup cover art from Cover Art Archive

    func fetchCoverArt(mbid: String) async -> Data? {
        await rateLimit()
        let urlStr = "https://coverartarchive.org/release/\(mbid)/front-500"
        guard let url = URL(string: urlStr) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        return try? await URLSession.shared.data(for: request).0
    }

    // MARK: - Parse response

    private func parseLookupResponse(data: Data, targetTitle: String, targetArtist: String?) throws -> AudioTags? {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let recordings = json?["recordings"] as? [[String: Any]],
              !recordings.isEmpty else { return nil }

        // Find best match
        for recording in recordings {
            guard let title  = recording["title"] as? String,
                  let score  = recording["score"] as? Int, score >= 80 else { continue }

            var tags = AudioTags.empty
            tags.title = title

            // Artist credit
            if let credits = recording["artist-credit"] as? [[String: Any]],
               let first   = credits.first,
               let artistObj = first["artist"] as? [String: Any] {
                tags.artist = artistObj["name"] as? String
            }

            // Release info (album, year, track)
            if let releases = recording["releases"] as? [[String: Any]],
               let rel     = releases.first {
                tags.album = rel["title"] as? String

                if let date = rel["date"] as? String, date.count >= 4 {
                    tags.year = Int(date.prefix(4))
                }

                if let media  = rel["media"] as? [[String: Any]],
                   let medium = media.first,
                   let tracks = medium["tracks"] as? [[String: Any]],
                   let track  = tracks.first {
                    if let numStr = track["number"] as? String { tags.trackNumber = Int(numStr) }
                    tags.trackTotal = medium["track-count"] as? Int
                }

                // Album artist
                if let artistCredit = rel["artist-credit"] as? [[String: Any]],
                   let first = artistCredit.first,
                   let a = first["artist"] as? [String: Any] {
                    tags.albumArtist = a["name"] as? String
                }
            }

            return tags
        }
        return nil
    }

    // MARK: - Rate limiter

    private func rateLimit() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequestTime)
        if elapsed < minInterval {
            try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
}
