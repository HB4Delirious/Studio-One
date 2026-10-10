import AppKit
import SwiftUI

/// Backs the browser: playlists, the tracks of whichever one is open, what's
/// coming up, and cover art.
///
/// Everything is fetched when first shown and then kept: the quickest Apple
/// Event here takes about 0.15 s.
@MainActor
final class LibraryModel: ObservableObject {

    @Published private(set) var playlists: [LibraryPlaylist] = []
    @Published private(set) var tracks: [LibraryTrack] = []
    @Published private(set) var upNext: UpNext?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published var selected: LibraryPlaylist?

    /// Songs in the guests' requests playlist, for its badge.
    @Published private(set) var requestCount: Int?

    /// The guests' requests playlist, when the player has one (Apple Music).
    var requestsPlaylist: LibraryPlaylist? {
        guard model?.musicSource == .appleMusic else { return nil }
        return playlists.first { $0.name == AppleMusicController.requestsPlaylist }
    }

    /// Playlist index → cover. Kept as NSImage so a redraw doesn't re-decode.
    @Published private(set) var covers: [Int: NSImage] = [:]
    private var coversInFlight: Set<Int> = []

    /// Bumped when the library underneath changes (another source, a reload),
    /// so a cover still loading can't land on whichever playlist now has its
    /// number.
    private var generation = 0
    /// The generation a playlist load is for; an older one's result is dropped.
    private var loadingFor: Int?

    /// Search spans both: what the host already owns and can play now, and the
    /// wider Apple Music catalogue, which can only be opened and added.
    @Published var query = ""
    @Published private(set) var libraryHits: [LibraryTrack] = []
    @Published private(set) var catalogHits: [CatalogTrack] = []
    @Published private(set) var searching = false

    private var searchTask: Task<Void, Never>?

    /// A catalogue track that has been opened in Music and is waiting to show
    /// up in the library. See `open(_:)`.
    @Published private(set) var awaiting: CatalogTrack?
    private var awaitTask: Task<Void, Never>?

    private weak var model: KaraokeModel?

    func attach(to model: KaraokeModel) {
        guard self.model !== model else { return }
        self.model = model
        playlists = []
        tracks = []
        upNext = nil
        covers = [:]
        coversInFlight = []
        generation += 1
        selected = nil
        failure = nil
    }

    var canBrowse: Bool { model?.browser?.canBrowseLibrary ?? false }

    func loadPlaylists() async {
        guard let browser = model?.browser, browser.canBrowseLibrary, playlists.isEmpty,
              loadingFor != generation else { return }
        let asked = generation
        loadingFor = asked
        loading = true
        defer {
            if loadingFor == asked { loadingFor = nil; loading = false }
        }
        do {
            let loaded = try await browser.playlists()
            guard generation == asked else { return }
            playlists = loaded
            failure = nil
            Diagnostics.log("library: \(playlists.count) playlists")
            await refreshRequestCount()
        } catch {
            guard generation == asked else { return }
            failure = error.localizedDescription
            // Not an error while the player isn't open: it loads once it is.
            if case PlayerError.notRunning = error {
                Diagnostics.log("library: waiting for the player to open")
            } else {
                Diagnostics.log("ERROR library playlists: \(error.localizedDescription)")
            }
        }
    }

    /// Starts over — after signing in or out of Spotify.
    func reload() async {
        playlists = []
        tracks = []
        covers = [:]
        coversInFlight = []
        generation += 1
        selected = nil
        failure = nil
        await loadPlaylists()
        await refreshUpNext()
    }

    var isSpotify: Bool { model?.musicSource == .spotify }

    func open(_ playlist: LibraryPlaylist) async {
        guard let browser = model?.browser else { return }
        selected = playlist
        tracks = []
        failure = nil
        loading = true
        defer { loading = false }
        do {
            let loaded = try await browser.tracks(in: playlist)
            // Another playlist was opened meanwhile. Matched as the same
            // playlist, not the same value: a refresh may have moved it.
            guard let selected, Self.same(selected, playlist) else { return }
            tracks = loaded
            Diagnostics.log("library: \(tracks.count) tracks in \(playlist.name)")
        } catch {
            guard let selected, Self.same(selected, playlist) else { return }
            failure = error.localizedDescription
        }
    }

    func refreshUpNext() async {
        guard let browser = model?.browser, browser.canBrowseLibrary else {
            upNext = nil
            return
        }
        // More than fits on screen; the playlist may hold thousands.
        upNext = try? await browser.upNext(limit: 40)
    }

    /// Debounced: every keystroke would otherwise be an Apple Event into Music
    /// and a round trip to Apple.
    func search() {
        searchTask?.cancel()
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wanted.count >= 2 else {
            libraryHits = []
            catalogHits = []
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            let browser = model?.browser
            async let mine: [LibraryTrack] = {
                guard let browser else { return [] }
                return (try? await browser.searchLibrary(wanted)) ?? []
            }()
            // On Spotify, `searchLibrary` already covers all of Spotify, and
            // those results play; the iTunes catalogue is Apple Music's.
            async let theirs: [CatalogTrack] = isSpotify ? [] : CatalogSearch.shared.search(wanted)
            let (owned, catalogue) = await (mine, theirs)
            guard !Task.isCancelled else { return }

            // Songs already owned show once, in the library list.
            let have = Set(owned.map { "\($0.name.lowercased())|\($0.artist.lowercased())" })
            let rest = catalogue.filter {
                !have.contains("\($0.name.lowercased())|\($0.artist.lowercased())")
            }
            Diagnostics.log("search \"\(wanted)\": library \(owned.count), catalogue \(catalogue.count) → \(rest.count) after dedupe")
            libraryHits = owned
            catalogHits = rest
            searching = false
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        libraryHits = []
        catalogHits = []
        searching = false
    }

    /// Opens a catalogue track in Music and starts it once it's in the library.
    ///
    /// Music's scripting can't play a catalogue track by any route (it stalls
    /// on a placeholder), and MusicKit needs a developer Team ID. So the song's
    /// page is opened for its one-click + button, and the library is watched
    /// until it arrives — after which it can be queued and requested like any
    /// other.
    func open(_ track: CatalogTrack) {
        guard let url = track.openURL else { return }
        NSWorkspace.shared.open(url)
        watchForArrival(of: track)
    }

    func stopWaiting() {
        awaitTask?.cancel()
        awaitTask = nil
        awaiting = nil
    }

    /// Polled, since Music announces nothing when a track is added: a search
    /// every 1.5 s for two minutes.
    private func watchForArrival(of track: CatalogTrack) {
        awaitTask?.cancel()
        awaiting = track
        awaitTask = Task {
            defer { if awaiting == track { awaiting = nil; awaitTask = nil } }
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let browser = model?.browser else { return }
                let hits = (try? await browser.searchLibrary(Self.searchTerm(for: track))) ?? []
                guard !Task.isCancelled else { return }
                if let match = hits.first(where: { Self.isSame($0, as: track) }) {
                    try? await browser.play(match)
                    Diagnostics.log("catalogue: \(track.name) added to the library, started it")
                    return
                }
            }
            Diagnostics.log("catalogue: gave up waiting for \(track.name)")
        }
    }

    /// The title without its bracketed credits, which the store and the
    /// library copy often disagree on.
    private static func searchTerm(for track: CatalogTrack) -> String {
        let stripped = outsideBrackets(track.name).trimmingCharacters(in: .whitespaces)
        return stripped.count >= 2 ? stripped : track.name
    }

    /// Library and store copies rarely match character for character, so this
    /// compares the bare title, a shared artist word and the running time.
    private static func isSame(_ owned: LibraryTrack, as wanted: CatalogTrack) -> Bool {
        guard bare(owned.name) == bare(wanted.name) else { return false }
        if wanted.duration > 0, owned.duration > 0,
           abs(owned.duration - wanted.duration) > 5 { return false }
        let mine = Set(words(owned.artist)), theirs = Set(words(wanted.artist))
        return !mine.isDisjoint(with: theirs)
    }

    private static func bare(_ text: String) -> String {
        outsideBrackets(text).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func outsideBrackets(_ text: String) -> String {
        var kept = ""
        var depth = 0
        for character in text {
            if character == "(" || character == "[" { depth += 1 }
            else if character == ")" || character == "]" { depth = max(0, depth - 1) }
            else if depth == 0 { kept.append(character) }
        }
        return kept
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    /// One Apple Event, after anything that may have changed it: a request,
    /// a song change, the playlists loading.
    func refreshRequestCount() async {
        guard let music = model?.browser as? AppleMusicController, model?.musicSource == .appleMusic else {
            if requestCount != nil { requestCount = nil }
            return
        }
        let count = await music.requestCount()
        // Made since the list was read — by the first request, or Queue
        // Again: read the list again so it shows.
        if count != nil, requestsPlaylist == nil { await refreshPlaylists() }
        if requestCount != count { requestCount = count }
    }

    /// The playlists read again, keeping what's open, for one made since
    /// launch. Covers are keyed by position, which a new playlist shifts, so
    /// each is carried to its playlist's new place.
    private func refreshPlaylists() async {
        guard let browser = model?.browser, browser.canBrowseLibrary, loadingFor == nil else { return }
        let asked = generation
        guard let loaded = try? await browser.playlists(), generation == asked, loaded != playlists else { return }
        var moved: [Int: NSImage] = [:]
        for playlist in loaded {
            if let old = playlists.first(where: { Self.same($0, playlist) }), let cover = covers[old.index] {
                moved[playlist.index] = cover
            }
        }
        generation += 1
        playlists = loaded
        covers = moved
        coversInFlight = []
        if let open = selected { selected = loaded.first { Self.same($0, open) } }
    }

    /// The same playlist, wherever it now sits: by persistent ID where the
    /// player has one (Apple Music); without one, only the very same entry —
    /// two of Spotify's can share a name.
    private static func same(_ a: LibraryPlaylist, _ b: LibraryPlaylist) -> Bool {
        a.persistentID != nil ? a.persistentID == b.persistentID : a == b
    }

    func play(_ track: LibraryTrack) {
        model?.playChosen(track)
    }

    /// Loaded once, and only when a playlist's card appears.
    func cover(for playlist: LibraryPlaylist) {
        guard covers[playlist.index] == nil,
              !coversInFlight.contains(playlist.index),
              let browser = model?.browser, browser.canBrowseLibrary else { return }
        coversInFlight.insert(playlist.index)
        let asked = generation
        Task {
            let data = await browser.cover(of: playlist)
            guard generation == asked else { return }
            coversInFlight.remove(playlist.index)
            if let data, let image = NSImage(data: data) {
                covers[playlist.index] = image
            }
        }
    }
}
