import Foundation

/// Musical key and tempo for a track.
struct TrackAnalysis: Equatable, Sendable {
    var key: String?
    var tempo: Double?
    /// Set when the two sources disagree by roughly 2×, which means one of them
    /// read the track at half or double time. That's the only tempo error big
    /// enough to hear — quantisation is thousandths of a BPM by comparison.
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

/// Fetches key and tempo from GetSongBPM (https://getsongbpm.com).
///
/// Spotify's `audio-features` endpoint is the usual source for this, but it
/// returns 403 for every app created after November 2024 — including ours — so
/// it isn't an option. GetSongBPM is free, but it needs a personal API key and
/// its terms require a visible link back to their site; that link lives in the
/// Settings sheet next to the key field.
actor AnalysisProvider {

    static let shared = AnalysisProvider()

    private var cache: [String: TrackAnalysis] = [:]

    /// Read once per launch. A keychain read can raise an authorisation prompt,
    /// and asking on every track change would stall each lookup behind a dialog
    /// — silently, since a pending prompt looks identical to a slow network.
    private var cachedKey: String??

    /// Apple Music track ID → Spotify track ID, once resolved. The bridge costs
    /// a search, and the answer never changes for a given track.
    private var bridge: [String: String?] = [:]
    private let base = "https://api.getsong.co"
    private let userAgent = "SpotifyKaraoke/1.0 (macOS; personal karaoke client)"

    func analysis(for track: SpotifyTrack) async -> TrackAnalysis? {
        let cacheKey = track.trackID
        if let hit = cache[cacheKey] { return hit }

        // Both sources, concurrently. ReccoBeats is keyed by Spotify track ID
        // so it's the more trustworthy match, but querying GetSongBPM too gives
        // a second opinion to check the tempo against.
        //
        // Apple Music tracks carry an "am:" identifier, so the same recording
        // is looked up on Spotify first and ReccoBeats asked with that ID.
        // Without this, Apple Music ran on GetSongBPM alone — which is why key
        // and tempo went missing so much more often on that source.
        // Note this tests `uri`, not `cacheKey`: `trackID` splits the uri on
        // ":" and keeps the last component, so an Apple Music id arrives here
        // as bare hex with the "am:" already stripped. Checking the wrong one
        // meant ReccoBeats was being asked about Apple Music persistent IDs,
        // which it can never know — a guaranteed miss on every single track.
        async let primary: TrackAnalysis? = {
            guard track.uri.hasPrefix("am:") else { return await reccoBeats(trackID: cacheKey) }
            guard let id = await bridgedID(for: track) else { return nil }
            return await reccoBeats(trackID: id)
        }()
        async let secondary = getSongBPM(track)
        let (recco, gsb) = await (primary, secondary)

        Diagnostics.log("  analysis sources: reccobeats=\(recco?.tempo.map { String(format: "%.1f", $0) } ?? "none") getsongbpm=\(gsb?.tempo.map { String(format: "%.1f", $0) } ?? "none")")

        guard var result = recco ?? gsb else { return nil }

        if let a = recco?.tempo, let b = gsb?.tempo, a > 0, b > 0 {
            let ratio = max(a, b) / min(a, b)
            result.halfTimeSuspect = abs(ratio - 2) < 0.08
        }

        cache[cacheKey] = result
        return result
    }

    /// After a new API key is saved. The key itself is cached too, so
    /// clearing only the results kept using the old key — or none — until the
    /// app was relaunched.
    func invalidate() {
        cache.removeAll()
        cachedKey = nil
    }

    // MARK: - Spotify bridge

    /// Find the same recording on Spotify, so ReccoBeats has an ID to key off.
    ///
    /// Guarded three ways, because a wrong match here publishes someone else's
    /// key and tempo to Logic with no sign anything is amiss: the artist has to
    /// correspond whole-word, the running time has to be within four seconds,
    /// and the titles have to share most of their words. A near-miss returns
    /// nothing rather than a guess.
    private func bridgedID(for track: SpotifyTrack) async -> String? {
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
    private static func titlesAgree(_ a: String, _ b: String) -> Bool {
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

    private func getSongBPM(_ track: SpotifyTrack) async -> TrackAnalysis? {
        guard let apiKey = songBPMKey(), !apiKey.isEmpty else { return nil }

        let title = LyricsProvider.normalizeTitle(track.name)
        guard !title.isEmpty else { return nil }

        // Full artist first, as for the lyrics: trimmed to its first name,
        // "Earth, Wind & Fire" becomes "Earth" — a different band, and a
        // different key sent to the tuners.
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

        // GetSongBPM matches loosely on title: asking for "Hello" by Adele will
        // happily return "Hello Babe" by Madeleine Peyroux. Take the first hit
        // whose artist actually corresponds, and show nothing rather than
        // someone else's key and tempo.
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

    /// Whole-word comparison, deliberately not substring: "Madeleine" contains
    /// the letters of "Adele", which is exactly how a search for Adele ends up
    /// returning Madeleine Peyroux's key and tempo.
    private static func artist(_ record: [String: Any], matches wanted: String) -> Bool {
        guard let name = (record["artist"] as? [String: Any])?["name"] as? String else { return false }
        return names(name, match: wanted)
    }

    /// Whole-word comparison for two artist strings.
    private static func names(_ a: String, match b: String) -> Bool {
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

    /// "F#m" reads better as "F♯m" at a glance.
    private static func prettyKey(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .replacingOccurrences(of: "#", with: "♯")
            .replacingOccurrences(of: "b ", with: "♭ ")
    }
}
