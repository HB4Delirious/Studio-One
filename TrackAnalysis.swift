import Foundation

/// Musical key and tempo for a track.
struct TrackAnalysis: Equatable, Sendable, Codable {
    var key: String?
    var tempo: Double?
    /// The two sources disagree by about 2×: one read the song at half or
    /// double time, the only tempo error big enough to hear.
    var halfTimeSuspect: Bool = false

    var isEmpty: Bool { key == nil && tempo == nil }

    /// Whole beats per minute. The fractional part is real — sources report
    /// 130.03 — but it is noise at reading distance.
    static func bpmText(_ tempo: Double?) -> String {
        guard let tempo, tempo > 0 else { return "—" }
        return String(format: "%.0f", tempo)
    }

    /// The one-line form the menu bar shows: "G♯m · 130".
    var summary: String {
        let parts = [key, tempo.map { _ in Self.bpmText(tempo) }].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// Key and tempo from ReccoBeats (by Spotify track ID), with GetSongBPM (by
/// title and artist, with a free personal key) as a second opinion, and the
/// song's catalogue preview, analysed here, for whatever both lack — so a
/// service being down costs accuracy rather than every key. Spotify's own
/// `audio-features` refuses apps created after November 2024. GetSongBPM's
/// terms require the link in Settings › Key & tempo.
///
/// What the services found is kept on disk too, like the lyrics: a song looked
/// up once — played, or prepared ahead of a night (see `Preparation`) — has
/// its key at once next time, with or without the internet. A value only the
/// preview gave is kept for this launch only, so the services are asked again
/// next time rather than a weaker reading standing for good; whatever the
/// services did give is kept, and stands in when they can't be reached.
actor AnalysisProvider {

    static let shared = AnalysisProvider()

    private var cache: [String: TrackAnalysis] = [:]

    private lazy var folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyKaraoke/Analysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Read once per launch: a keychain read can raise a prompt, and each
    /// lookup would wait on it.
    private var cachedKey: String??

    /// Track ID → Spotify track ID, for songs found by search.
    private var bridge: [String: String?] = [:]
    private let base = "https://api.getsong.co"
    private let userAgent = "SpotifyKaraoke/1.0 (macOS; personal karaoke client)"

    func analysis(for track: PlayerTrack) async -> TrackAnalysis? {
        let cacheKey = track.trackID
        if let hit = cache[cacheKey] { return hit }
        // Complete from the services: done. Part of it: asked again below,
        // with this to fall back on.
        let saved = readDisk(cacheKey)
        if let saved, saved.key != nil, saved.tempo != nil {
            cache[cacheKey] = saved
            return saved
        }

        // All three at once. Anything that isn't a Spotify track (Apple Music, a
        // local file) is found on Spotify first for ReccoBeats' sake — tested
        // on the URI, since `trackID` has dropped its prefix.
        async let primary: TrackAnalysis? = {
            guard !track.uri.hasPrefix("spotify:track:") else { return await reccoBeats(trackID: cacheKey) }
            guard let id = await bridgedID(for: track) else { return nil }
            return await reccoBeats(trackID: id)
        }()
        async let secondary = getSongBPM(track)
        // Started alongside rather than after, to land before the singing
        // does; cancelled on leaving if the others were enough.
        async let fallback = PreviewAnalysis.analysis(for: track)
        let (recco, gsb) = await (primary, secondary)

        var result = TrackAnalysis(key: recco?.key ?? gsb?.key ?? saved?.key,
                                   tempo: recco?.tempo ?? gsb?.tempo ?? saved?.tempo)
        // What the services gave, now or before: the part kept on disk.
        var fromServices = result
        var preview: TrackAnalysis?
        if result.key == nil || result.tempo == nil {
            preview = await fallback
            result.key = result.key ?? preview?.key
            result.tempo = result.tempo ?? preview?.tempo
        }

        Diagnostics.log("  analysis sources: reccobeats=\(Self.describe(recco)) getsongbpm=\(Self.describe(gsb)) preview=\(Self.describe(preview))")

        guard !result.isEmpty else { return nil }

        if let a = recco?.tempo, let b = gsb?.tempo, a > 0, b > 0 {
            let ratio = max(a, b) / min(a, b)
            result.halfTimeSuspect = abs(ratio - 2) < 0.08
        } else {
            result.halfTimeSuspect = saved?.halfTimeSuspect ?? false
        }
        fromServices.halfTimeSuspect = result.halfTimeSuspect

        cache[cacheKey] = result
        if !fromServices.isEmpty { writeDisk(cacheKey, fromServices) }
        return result
    }

    /// What's kept on disk for a song — the services' part — for showing
    /// which values will be there without the internet.
    func saved(_ track: PlayerTrack) -> TrackAnalysis? {
        readDisk(track.trackID)
    }

    // MARK: - Disk

    private func file(_ key: String) -> URL {
        folder.appendingPathComponent(key.map { "/:\\".contains($0) ? "_" : String($0) }.joined() + ".json")
    }

    /// On disk, wrapped: files from before preview readings were left out
    /// don't decode, and are looked up again once.
    private struct Saved: Codable {
        let fromServices: TrackAnalysis
    }

    private func readDisk(_ key: String) -> TrackAnalysis? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            // From before the wrapper, unread from now on: cleared, not kept.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return saved.fromServices.isEmpty ? nil : saved.fromServices
    }

    private func writeDisk(_ key: String, _ analysis: TrackAnalysis) {
        guard let data = try? JSONEncoder().encode(Saved(fromServices: analysis)) else { return }
        try? data.write(to: file(key), options: .atomic)
    }

    private static func describe(_ analysis: TrackAnalysis?) -> String {
        guard let analysis, !analysis.isEmpty else { return "none" }
        return analysis.summary.replacingOccurrences(of: " · ", with: " ")
    }

    /// After a new API key is saved: drops the results, saved ones included,
    /// and the cached key.
    func invalidate() {
        cache.removeAll()
        cachedKey = nil
        let saved = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in saved where url.pathExtension == "json" { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Spotify bridge

    /// Find the same recording on Spotify, so ReccoBeats has an ID to key off.
    ///
    /// A wrong match would send another song's key to Logic unnoticed, so the
    /// artist must match whole-word, the length within four seconds, and the
    /// titles mostly; anything less is no match.
    private func bridgedID(for track: PlayerTrack) async -> String? {
        if let known = bridge[track.trackID] { return known }

        let hits = (try? await SpotifyAPI.shared.search("\(track.name) \(track.artist)", limit: 10)) ?? []
        let match = hits.first { hit in
            Self.names(hit.artist, match: track.artist)
                && abs(hit.duration - track.duration) <= 4
                && Self.titlesAgree(hit.name, track.name)
        }
        bridge[track.trackID] = match?.id
        Diagnostics.log("  spotify bridge: \(match.map { "\($0.name) — \($0.artist)" } ?? "no confident match")")
        return match?.id
    }

    /// Most of the words in the shorter title have to appear in the longer one.
    /// Lets "Circles" match "Circles (Live)" while keeping "Hello" away from
    /// "Hello Babe".
    static func titlesAgree(_ a: String, _ b: String) -> Bool {
        let left = words(in: a), right = words(in: b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let (fewer, more) = left.count <= right.count ? (left, right) : (right, left)
        return Double(fewer.intersection(more).count) / Double(fewer.count) >= 0.6
    }

    // MARK: - ReccoBeats

    private static let pitchNames = ["C", "C♯", "D", "D♯", "E", "F",
                                     "F♯", "G", "G♯", "A", "A♯", "B"]

    private func reccoBeats(trackID: String) async -> TrackAnalysis? {
        var components = URLComponents(string: "https://api.reccobeats.com/v1/audio-features")!
        components.queryItems = [URLQueryItem(name: "ids", value: trackID)]

        guard let url = components.url,
              let object = await json(url),
              let content = object["content"] as? [[String: Any]],
              let record = content.first else { return nil }

        var key: String?
        // Pitch class 0–11 with a separate major/minor flag; -1 means unknown.
        if let pitch = record["key"] as? Int, (0...11).contains(pitch) {
            let minor = (record["mode"] as? Int) == 0
            key = Self.pitchNames[pitch] + (minor ? "m" : "")
        }

        let analysis = TrackAnalysis(key: key, tempo: Self.number(record["tempo"]))
        return analysis.isEmpty ? nil : analysis
    }

    // MARK: - GetSongBPM

    private func songBPMKey() -> String? {
        if let cachedKey { return cachedKey }
        let value = Credentials.read(.songBPM)
        cachedKey = value
        Diagnostics.log("  getsongbpm key: \((value?.isEmpty == false) ? "available" : "unavailable — keychain denied or empty")")
        return value
    }

    private func getSongBPM(_ track: PlayerTrack) async -> TrackAnalysis? {
        guard let apiKey = songBPMKey(), !apiKey.isEmpty else { return nil }

        let title = LyricsProvider.normalizeTitle(track.name)
        guard !title.isEmpty else { return nil }

        // The full artist first, as for the lyrics.
        let full = track.artist.trimmingCharacters(in: .whitespaces)
        let primary = LyricsProvider.normalizeArtist(track.artist)
        var found: (id: String?, analysis: TrackAnalysis)?
        for artist in primary == full ? [full] : [full, primary] {
            found = await search(title: title, artist: artist, apiKey: apiKey)
            if found != nil { break }
        }
        guard let hit = found else { return nil }

        var analysis = hit.analysis
        if analysis.isEmpty, let id = hit.id, let detail = await song(id: id, apiKey: apiKey) {
            analysis = detail
        }
        return analysis.isEmpty ? nil : analysis
    }

    // MARK: - Requests

    private func search(title: String, artist: String,
                        apiKey: String) async -> (id: String?, analysis: TrackAnalysis)? {
        var components = URLComponents(string: base + "/search/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "type", value: "both"),
            URLQueryItem(name: "lookup", value: "song:\(title) artist:\(artist)")
        ]
        guard let url = components.url, let object = await json(url) else { return nil }

        // `search` is an array of hits, or an object carrying an error when
        // nothing matched. Tolerate both rather than failing the decode.
        guard let hits = object["search"] as? [[String: Any]] else { return nil }

        // Its title matching is loose ("Hello" by Adele finds "Hello Babe"), so
        // the artist has to match too.
        guard let hit = hits.first(where: { Self.artist($0, matches: artist) }) else { return nil }
        return (hit["id"] as? String, Self.analysis(from: hit))
    }

    private func song(id: String, apiKey: String) async -> TrackAnalysis? {
        var components = URLComponents(string: base + "/song/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "id", value: id)
        ]
        guard let url = components.url, let object = await json(url),
              let song = object["song"] as? [String: Any] else { return nil }
        let analysis = Self.analysis(from: song)
        return analysis.isEmpty ? nil : analysis
    }

    /// Hand-parsed rather than Codable: the API returns tempo as a string on some
    /// records and a number on others, and swaps `search` between array and object.
    private func json(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Parsing

    private static func analysis(from record: [String: Any]) -> TrackAnalysis {
        TrackAnalysis(key: prettyKey(record["key_of"]), tempo: number(record["tempo"]))
    }

    /// Whole words, not substrings: "Madeleine" contains "Adele".
    private static func artist(_ record: [String: Any], matches wanted: String) -> Bool {
        guard let name = (record["artist"] as? [String: Any])?["name"] as? String else { return false }
        return names(name, match: wanted)
    }

    /// Whole-word comparison for two artist strings.
    static func names(_ a: String, match b: String) -> Bool {
        let found = words(in: a)
        let target = words(in: b)
        guard !found.isEmpty, !target.isEmpty else { return false }
        if found == target { return true }
        // Allows "Simon & Garfunkel" to match "Simon and Garfunkel" without
        // letting unrelated names through.
        let (fewer, more) = found.count <= target.count ? (found, target) : (target, found)
        return fewer.isSubset(of: more)
    }

    private static func words(in raw: String) -> Set<String> {
        let expanded = raw.lowercased().replacingOccurrences(of: "&", with: " and ")
        return Set(expanded.split { !$0.isLetter && !$0.isNumber }
                           .map(String.init)
                           .filter { $0.count > 1 })
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// "F#m" reads better as "F♯m" at a glance. Nil for anything that
    /// isn't a key — GetSongBPM has sent a bare "m" — so another source's
    /// key is used instead of none.
    private static func prettyKey(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard MIDIBridge.encode(key: trimmed) != nil else { return nil }
        return trimmed
            .replacingOccurrences(of: "#", with: "♯")
            .replacingOccurrences(of: "b ", with: "♭ ")
    }
}
