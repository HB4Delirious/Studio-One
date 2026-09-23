import AppKit

/// A track found in the Apple Music catalogue rather than the local library.
struct CatalogTrack: Identifiable, Hashable {
    let id: Int                 // iTunes trackId
    let name: String
    let artist: String
    let album: String
    let duration: Double
    let artworkURL: URL?
    let openURL: URL?           // music.apple.com page for the track
}

/// Searches the whole Apple Music catalogue through the public iTunes Search
/// API — no key, no account.
///
/// This exists because Music's own scripting `search` only looks inside a
/// playlist, so the app could never see past what the host already owned.
///
/// What it deliberately does not do is play the result. Music cannot be told to
/// play a catalogue track: `open location` on a music.apple.com URL navigates
/// to it and leaves a paused placeholder named after the album id, and a
/// following `play` does nothing — checked against the https, music:// and
/// itmss:// forms, all identical. The only scriptable sources are "Library" and
/// "iTunes Store". So a catalogue hit is offered as somewhere to go and add,
/// and it becomes playable once it is in the library.
actor CatalogSearch {

    static let shared = CatalogSearch()

    private var cache: [String: [CatalogTrack]] = [:]

    func search(_ query: String, limit: Int = 25) async -> [CatalogTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        if let hit = cache[trimmed.lowercased()] { return hit }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // A cancelled lookup is the debounce doing its job — every keystroke
            // cancels the one before it — so only a real failure is worth a line.
            if !Task.isCancelled {
                Diagnostics.log("  catalogue: \(trimmed) failed — \(error.localizedDescription)")
            }
            return []
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Diagnostics.log("  catalogue: \(trimmed) HTTP \(status)")
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            Diagnostics.log("  catalogue: \(trimmed) unreadable, \(data.count) bytes")
            return []
        }

        let tracks = results.compactMap { record -> CatalogTrack? in
            guard let id = record["trackId"] as? Int,
                  let name = record["trackName"] as? String,
                  let artist = record["artistName"] as? String else { return nil }
            return CatalogTrack(
                id: id,
                name: name,
                artist: artist,
                album: record["collectionName"] as? String ?? "",
                duration: ((record["trackTimeMillis"] as? Int) ?? 0) > 0
                    ? Double(record["trackTimeMillis"] as! Int) / 1000 : 0,
                artworkURL: (record["artworkUrl100"] as? String).flatMap(URL.init(string:)),
                openURL: (record["trackViewUrl"] as? String).flatMap(URL.init(string:)))
        }
        cache[trimmed.lowercased()] = tracks
        return tracks
    }
}
