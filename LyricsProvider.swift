import Foundation

struct LyricsRecord: Decodable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum LyricsResult {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}

/// Fetches timed lyrics from LRCLIB (https://lrclib.net) — open, free, no API key.
/// Results are cached on disk so replaying a track is instant and offline-safe.
actor LyricsProvider {

    static let shared = LyricsProvider()

    private let base = URL(string: "https://lrclib.net")!
    private let userAgent = "SpotifyKaraoke/1.0 (macOS; personal karaoke client)"
    private var memoryCache: [String: LyricsResult] = [:]

    private lazy var cacheDirectory: URL = {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyKaraoke/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    // MARK: - Public

    func lyrics(for track: SpotifyTrack) async -> LyricsResult {
        let key = track.trackID

        if let cached = memoryCache[key] { return cached }
        // Your own timing wins over anything downloaded.
        if let mine = readUser(key) {
            let parsed = LRCParser.parse(mine)
            if !parsed.isEmpty {
                let result = LyricsResult.synced(parsed)
                memoryCache[key] = result
                return result
            }
        }
        if let disk = readDisk(key) {
            let parsed = LRCParser.parse(disk)
            if !parsed.isEmpty {
                let result = LyricsResult.synced(parsed)
                memoryCache[key] = result
                return result
            }
        }

        let result = await fetch(track)
        memoryCache[key] = result
        return result
    }

    /// Force a re-fetch, e.g. when the auto match is obviously the wrong song.
    func invalidate(trackID: String) {
        memoryCache[trackID] = nil
        try? FileManager.default.removeItem(at: file(for: trackID))
    }

    // MARK: - Fetching

    private func fetch(_ track: SpotifyTrack) async -> LyricsResult {
        let title = Self.normalizeTitle(track.name)

        // The artist as given first, then just the first name in it. Cutting
        // straight to the first name — the old way — turned "Earth, Wind &
        // Fire" into "Earth", which LRCLIB matches to a different band, and
        // "Daryl Hall & John Oates" into "Daryl Hall", which found only
        // untimed lyrics where the full name finds timed ones. Checked against
        // LRCLIB for both. Featured-artist credits still fall back correctly.
        let full = track.artist.trimmingCharacters(in: .whitespaces)
        let primary = Self.normalizeArtist(track.artist)
        let artists = primary == full ? [full] : [full, primary]

        var untimed: [LyricsRecord?] = []
        for artist in artists {
            // Both lookups at once: they are independent, and one after the
            // other doubled the wait for every song.
            async let exactLookup = try? exactMatch(title: title, artist: artist,
                                                    album: track.album, duration: track.duration)
            async let searchLookup = try? bestSearchMatch(title: title, artist: artist,
                                                          duration: track.duration)
            let (exact, searched) = await (exactLookup, searchLookup)

            // Timed lyrics are the whole point, so look for a synced record in
            // both places before settling. The exact-match endpoint frequently
            // holds a plain-only entry for a track that has perfectly good
            // synced versions in search.
            if let result = interpret(exact ?? nil, key: track.trackID, requireSynced: true) {
                Diagnostics.log("  lyrics source: exact match, \(artist) (synced)")
                return result
            }
            if let result = interpret(searched ?? nil, key: track.trackID, requireSynced: true) {
                Diagnostics.log("  lyrics source: search, \(artist) (synced)")
                return result
            }
            untimed += [exact ?? nil, searched ?? nil]
        }

        // LRCLIB has nothing timed: try NetEase, which often has timing word
        // by word. Checked before settling for untimed text. The original
        // title is used as well as the cleaned one, since NetEase's own
        // titles keep things like "(Remastered)" less often than Spotify's.
        if NetEaseLyrics.isEnabled {
            for name in Array(Set([title, track.name])) {
                guard let found = await NetEaseLyrics.lyrics(title: name, artist: full, duration: track.duration) else { continue }
                let lines = LRCParser.parse(found.lrc)
                guard !lines.isEmpty else { continue }
                writeDisk(track.trackID, contents: found.lrc)
                Diagnostics.log("  lyrics source: NetEase (\(found.wordTimed ? "word-timed" : "line-timed"))")
                return .synced(lines)
            }
        }

        // Nothing timed anywhere — fall back to whatever text exists.
        for record in untimed {
            if let result = interpret(record, key: track.trackID, requireSynced: false) {
                Diagnostics.log("  lyrics source: plain only")
                return result
            }
        }
        Diagnostics.log("  lyrics source: none — LRCLIB had nothing for \(title) / \(full)")
        return .notFound
    }

    private func exactMatch(title: String, artist: String,
                            album: String, duration: Double) async throws -> LyricsRecord? {
        var components = URLComponents(url: base.appendingPathComponent("api/get"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = components.url else { return nil }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(LyricsRecord.self, from: data)
    }

    private func bestSearchMatch(title: String, artist: String,
                                 duration: Double) async throws -> LyricsRecord? {
        var components = URLComponents(url: base.appendingPathComponent("api/search"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = components.url else { return nil }
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let records = try? JSONDecoder().decode([LyricsRecord].self, from: data) else { return nil }

        // Closest runtime wins. A different master, a live take or an extended
        // mix carries timings that drift further and further out as the song
        // goes on, and picking one of those is indistinguishable from the app
        // losing sync — so how far off the chosen one is gets recorded either
        // way, and a bad gap is called out rather than left to be guessed at.
        let best = records
            .filter { ($0.syncedLyrics?.isEmpty == false) || ($0.instrumental == true) }
            .min { lhs, rhs in
                abs((lhs.duration ?? 0) - duration) < abs((rhs.duration ?? 0) - duration)
            }

        if let best, let found = best.duration {
            let gap = found - duration
            if abs(gap) > Self.durationTolerance {
                Diagnostics.log(String(format:
                    "  WARNING lyrics are for a %.0fs version, this track is %.0fs (%+.0fs) — expect drift",
                    found, duration, gap))
            } else {
                Diagnostics.log(String(format: "  lyrics match: %+.1fs from track length", gap))
            }
        }
        return best ?? records.first
    }

    /// Two or three seconds covers a trimmed intro or a fade; beyond this it is
    /// a different recording, not the same one measured differently.
    private static let durationTolerance: Double = 4

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        return request
    }

    /// With `requireSynced`, returns nil rather than settling for plain text —
    /// letting the caller check another source before giving up on timing.
    private func interpret(_ record: LyricsRecord?, key: String,
                           requireSynced: Bool) -> LyricsResult? {
        guard let record else { return nil }
        if record.instrumental == true { return .instrumental }

        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty {
                writeDisk(key, contents: synced)
                return .synced(lines)
            }
        }

        guard !requireSynced else { return nil }
        if let plain = record.plainLyrics, !plain.isEmpty { return .plain(plain) }
        return nil
    }

    // MARK: - Your own timing
    //
    // Tapped out in the Controls window, and kept apart from the download
    // cache: "Reload lyrics" clears that cache, and must never take an
    // evening's tapping with it.

    private lazy var userDirectory: URL = {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyKaraoke/Lyrics/Timed by you", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    private func userFile(for key: String) -> URL {
        let safe = key.map { "/:\\".contains($0) ? "_" : String($0) }.joined()
        return userDirectory.appendingPathComponent("\(safe).lrc")
    }

    private func readUser(_ key: String) -> String? {
        try? String(contentsOf: userFile(for: key), encoding: .utf8)
    }

    func userTimingText(trackID: String) -> String? { readUser(trackID) }

    func hasUserTiming(trackID: String) -> Bool {
        FileManager.default.fileExists(atPath: userFile(for: trackID).path)
    }

    /// Saves and takes effect at once. Returns the parsed lines, empty if the
    /// text didn't parse (in which case nothing is saved).
    func saveUserTiming(_ lrc: String, trackID: String) -> [LyricLine] {
        let parsed = LRCParser.parse(lrc)
        guard !parsed.isEmpty else { return [] }
        try? lrc.write(to: userFile(for: trackID), atomically: true, encoding: .utf8)
        memoryCache[trackID] = .synced(parsed)
        return parsed
    }

    func removeUserTiming(trackID: String) {
        try? FileManager.default.removeItem(at: userFile(for: trackID))
        memoryCache[trackID] = nil
    }

    // MARK: - Disk cache

    private func readDisk(_ key: String) -> String? {
        try? String(contentsOf: file(for: key), encoding: .utf8)
    }

    private func writeDisk(_ key: String, contents: String) {
        try? contents.write(to: file(for: key), atomically: true, encoding: .utf8)
    }

    /// A track with no persistent ID is keyed by its title and artist, and a
    /// "/" in either would name a folder that doesn't exist — the lyrics
    /// silently never cached. Such keys are made safe; ordinary IDs, which
    /// are letters and digits, keep the name they already have on disk.
    private func file(for key: String) -> URL {
        let safe = key.map { "/:\\".contains($0) ? "_" : String($0) }.joined()
        return cacheDirectory.appendingPathComponent("\(safe).lrc")
    }

    // MARK: - Title cleanup
    //
    // Spotify titles carry a lot of baggage that LRCLIB doesn't index:
    // "Song - 2011 Remaster", "Song (feat. Someone)", "Song - Radio Edit".

    static func normalizeTitle(_ raw: String) -> String {
        var title = raw

        // " - 2011 Remaster", " - From \"Les Misérables\"" and friends.
        if let dash = title.range(of: " - "),
           containsVersionNoise(String(title[dash.upperBound...])) {
            title = String(title[..<dash.lowerBound])
        }

        // "(Remastered)", "(2015 Remaster)", "(Live at Wembley)". Only groups
        // that actually look like version noise — parentheses are part of plenty
        // of real titles, like "(Don't Fear) The Reaper".
        title = strippingNoisyGroups(title, open: "(", close: ")")
        title = strippingNoisyGroups(title, open: "[", close: "]")

        // Collaborator credits.
        for marker in ["(feat.", "(ft.", "(with ", "[feat.", "[ft."] {
            if let range = title.range(of: marker, options: .caseInsensitive) {
                title = String(title[..<range.lowerBound])
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private static let versionNoise = [
        "remaster", "remastered", "radio edit", "single version", "album version",
        "live at", "live from", "live in", "mono", "stereo", "deluxe",
        "bonus track", "explicit", "edit", "version", "anniversary",
        "re-recorded", "rerecorded", "from \"", "original motion picture",
        "soundtrack", "feat.", "ft."
    ]

    private static func containsVersionNoise(_ text: String) -> Bool {
        let lower = text.lowercased()
        return versionNoise.contains { lower.contains($0) }
    }

    /// Removes bracketed groups whose contents read as version noise, leaving
    /// brackets that belong to the title itself intact.
    private static func strippingNoisyGroups(_ text: String,
                                             open: Character, close: Character) -> String {
        var result = ""
        var group = ""
        var depth = 0

        for character in text {
            if character == open {
                depth += 1
                if depth == 1 { group = ""; continue }
            }
            if character == close, depth > 0 {
                depth -= 1
                if depth == 0 {
                    if !containsVersionNoise(group) {
                        result.append(open); result += group; result.append(close)
                    }
                    continue
                }
            }
            if depth > 0 { group.append(character) } else { result.append(character) }
        }
        if depth > 0 { result.append(open); result += group }   // unbalanced, keep
        return result
    }

    static func normalizeArtist(_ raw: String) -> String {
        // Spotify joins collaborators; LRCLIB indexes on the primary artist.
        for separator in ["; ", " & ", ", ", " feat. ", " ft. "] where raw.contains(separator) {
            return raw.components(separatedBy: separator)[0].trimmingCharacters(in: .whitespaces)
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }
}
