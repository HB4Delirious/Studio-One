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

    func lyrics(for track: PlayerTrack) async -> LyricsResult {
        await lookup(track).result
    }

    /// The lyrics, and whether the answer can be trusted: false when nothing
    /// was found only because LRCLIB couldn't be reached.
    func lookup(_ track: PlayerTrack) async -> (result: LyricsResult, reached: Bool) {
        let key = track.trackID

        if let cached = memoryCache[key] { return (cached, true) }
        // Your own timing wins over anything downloaded.
        if let mine = readUser(key) {
            let parsed = LRCParser.parse(mine)
            if !parsed.isEmpty {
                let result = LyricsResult.synced(parsed)
                memoryCache[key] = result
                return (result, true)
            }
        }
        if let disk = readDisk(key) {
            let parsed = LRCParser.parse(disk)
            if !parsed.isEmpty {
                let result = LyricsResult.synced(parsed)
                memoryCache[key] = result
                return (result, true)
            }
        }

        let (result, reached) = await fetch(track)
        // "Nothing found" is remembered only when LRCLIB actually answered,
        // not when it couldn't be reached.
        if case .notFound = result, !reached { return (result, false) }
        memoryCache[key] = result
        return (result, true)
    }

    /// Force a re-fetch, e.g. when the auto match is obviously the wrong song.
    func invalidate(trackID: String) {
        memoryCache[trackID] = nil
        try? FileManager.default.removeItem(at: file(for: trackID))
    }

    // MARK: - Fetching

    /// The lyrics, and whether every LRCLIB lookup got an answer — found or
    /// not — rather than failing to connect.
    private func fetch(_ track: PlayerTrack) async -> (LyricsResult, reached: Bool) {
        let title = Self.normalizeTitle(track.name)

        // The artist as given, then only the first name in it: "Earth, Wind &
        // Fire" cut to "Earth" matches a different band, but a featured
        // artist's credit needs cutting.
        let full = track.artist.trimmingCharacters(in: .whitespaces)
        let primary = Self.normalizeArtist(track.artist)
        let artists = primary == full ? [full] : [full, primary]

        var untimed: [LyricsRecord?] = []
        var reached = true
        for artist in artists {
            // Both at once; they're independent.
            async let exactLookup = Self.attempt {
                try await self.exactMatch(title: title, artist: artist,
                                          album: track.album, duration: track.duration)
            }
            async let searchLookup = Self.attempt {
                try await self.bestSearchMatch(title: title, artist: artist, duration: track.duration)
            }
            let (exactOutcome, searchOutcome) = await (exactLookup, searchLookup)
            let exact = exactOutcome.record, searched = searchOutcome.record
            if exactOutcome.failed || searchOutcome.failed { reached = false }

            // A timed record from either before settling for text: the exact
            // match is often untimed where search has timed versions.
            if let result = interpret(exact, key: track.trackID, requireSynced: true) {
                Diagnostics.log("  lyrics source: exact match, \(artist) (synced)")
                return (result, true)
            }
            if let result = interpret(searched, key: track.trackID, requireSynced: true) {
                Diagnostics.log("  lyrics source: search, \(artist) (synced)")
                return (result, true)
            }
            untimed += [exact, searched]
        }

        // Nothing timed on LRCLIB: NetEase, often timed word by word, before
        // settling for untimed text. With the cleaned title and the original.
        if NetEaseLyrics.isEnabled {
            for name in Array(Set([title, track.name])) {
                guard let found = await NetEaseLyrics.lyrics(title: name, artist: full, duration: track.duration) else { continue }
                let lines = LRCParser.parse(found.lrc)
                guard !lines.isEmpty else { continue }
                writeDisk(track.trackID, contents: found.lrc)
                Diagnostics.log("  lyrics source: NetEase (\(found.wordTimed ? "word-timed" : "line-timed"))")
                return (.synced(lines), true)
            }
        }

        // Nothing timed anywhere — fall back to whatever text exists.
        for record in untimed {
            if let result = interpret(record, key: track.trackID, requireSynced: false) {
                Diagnostics.log("  lyrics source: plain only")
                return (result, true)
            }
        }
        if reached {
            Diagnostics.log("  lyrics source: none — LRCLIB had nothing for \(title) / \(full)")
        } else {
            Diagnostics.log("  lyrics source: none — LRCLIB couldn't be reached")
        }
        return (.notFound, reached)
    }

    /// A lookup's record, and whether it failed to get an answer at all.
    private static func attempt(_ lookup: @Sendable () async throws -> LyricsRecord?) async
        -> (record: LyricsRecord?, failed: Bool) {
        do { return (try await lookup(), false) } catch { return (nil, true) }
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 is "no such song"; anything else but 200 is no answer at all.
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
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
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let records = try? JSONDecoder().decode([LyricsRecord].self, from: data) else { return nil }

        // Closest runtime wins: another master or a live take drifts further
        // out as the song goes on, which looks exactly like losing sync — so
        // the gap is logged either way.
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

    /// Seconds a runtime may differ and still be the same recording (a trimmed
    /// intro, a fade).
    private static let durationTolerance: Double = 4

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        return request
    }

    /// With `requireSynced`, nil rather than plain text, so the caller can try
    /// another source for timing first.
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
    // Kept apart from the download cache, which Reload lyrics clears.

    private lazy var userDirectory: URL = {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyKaraoke/Lyrics/Timed by you", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    private func userFile(for key: String) -> URL {
        userDirectory.appendingPathComponent(Self.fileName(key))
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

    private func file(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.fileName(key))
    }

    /// Keys that aren't plain IDs — a local file's URI, a title and artist —
    /// can hold "/" or ":". Ordinary IDs keep the names already on disk.
    private static func fileName(_ key: String) -> String {
        key.map { "/:\\".contains($0) ? "_" : String($0) }.joined() + ".lrc"
    }

    // MARK: - Title cleanup
    //
    // Titles carry versions and credits LRCLIB doesn't index: "Song - 2011
    // Remaster", "Song (feat. Someone)", "Song - Radio Edit".

    static func normalizeTitle(_ raw: String) -> String {
        var title = raw

        // " - 2011 Remaster", " - From \"Les Misérables\"" and friends.
        if let dash = title.range(of: " - "),
           containsVersionNoise(String(title[dash.upperBound...])) {
            title = String(title[..<dash.lowerBound])
        }

        // "(Remastered)", "(Live at Wembley)" — but not "(Don't Fear) The
        // Reaper": only groups that read as version noise.
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
        // LRCLIB indexes the primary artist: everything before the first
        // separator in the name.
        let cut = ["; ", " & ", ", ", " feat. ", " ft. "]
            .compactMap { raw.range(of: $0)?.lowerBound }
            .min()
        return String(cut.map { raw[..<$0] } ?? raw[...]).trimmingCharacters(in: .whitespaces)
    }
}
