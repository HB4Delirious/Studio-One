import AppKit
import SwiftUI

/// Backs the browser: playlists, the tracks of whichever one is open, what's
/// coming up, and cover art.
///
/// Everything here is fetched on demand and cached. Apple Events are not cheap
/// — the fastest call in this file is about 0.15s — so nothing is re-fetched on
/// a redraw, and nothing is fetched before something wants to show it.
@MainActor
final class LibraryModel: ObservableObject {

    @Published private(set) var playlists: [LibraryPlaylist] = []
    @Published private(set) var tracks: [LibraryTrack] = []
    @Published private(set) var upNext: UpNext?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published var selected: LibraryPlaylist?

    /// Playlist index → cover. Kept as NSImage so a redraw doesn't re-decode.
    @Published private(set) var covers: [Int: NSImage] = [:]
    private var coversInFlight: Set<Int> = []

    /// Bumped whenever the library underneath changes — another source, a
    /// reload. A cover still loading from before must not land on whatever
    /// playlist now has its number.
    private var generation = 0
    /// The generation a playlist load is running for. A load for an older
    /// generation doesn't block a new one, and its result is dropped.
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
        } catch {
            guard generation == asked else { return }
            failure = error.localizedDescription
            // Not an error worth the word when the player simply isn't open
            // yet: the library loads by itself the moment it is.
            if case SpotifyControllerError.notRunning = error {
                Diagnostics.log("library: waiting for the player to open")
            } else {
                Diagnostics.log("ERROR library playlists: \(error.localizedDescription)")
            }
        }
    }

    /// Throws away what was loaded and fetches again — after signing in to
    /// Spotify, when the library goes from nothing to everything.
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
            // Clicked something else meanwhile: that one's list is on its way,
            // and this one must not land under its name.
            guard selected == playlist else { return }
            tracks = loaded
            Diagnostics.log("library: \(tracks.count) tracks in \(playlist.name)")
        } catch {
            guard selected == playlist else { return }
            failure = error.localizedDescription
        }
    }

    func refreshUpNext() async {
        guard let browser = model?.browser, browser.canBrowseLibrary else {
            upNext = nil
            return
        }
        // Forty is more than fits on screen and keeps the payload small; a
        // library playlist can hold thousands of tracks.
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
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self else { return }

            let browser = await MainActor.run { self.model?.browser }
            async let mine: [LibraryTrack] = {
                guard let browser else { return [] }
                return (try? await browser.searchLibrary(wanted)) ?? []
            }()
            // The iTunes catalogue is Apple Music's. On Spotify, `searchLibrary`
            // already searches the whole of Spotify, and those results play.
            let spotify = await MainActor.run { self.isSpotify }
            async let theirs: [CatalogTrack] = spotify ? [] : CatalogSearch.shared.search(wanted)
            let (owned, catalogue) = await (mine, theirs)
            guard !Task.isCancelled else { return }

            // Anything already owned is shown in the first list; repeating it
            // under "Apple Music" would just look like a duplicate.
            let have = Set(owned.map { "\($0.name.lowercased())|\($0.artist.lowercased())" })
            let rest = catalogue.filter {
                !have.contains("\($0.name.lowercased())|\($0.artist.lowercased())")
            }
            Diagnostics.log("search \"\(wanted)\": library \(owned.count), catalogue \(catalogue.count) → \(rest.count) after dedupe")
            await MainActor.run {
                self.libraryHits = owned
                self.catalogHits = rest
                self.searching = false
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        libraryHits = []
        catalogHits = []
        searching = false
    }

    /// Open a catalogue track in Music and start it as soon as it can be
    /// started.
    ///
    /// Nothing here can play it directly. Music refuses a catalogue track from
    /// every angle its scripting offers: `open location` then `play` leaves the
    /// player paused on a placeholder named after the album id, `playpause` and
    /// `play current track` do the same, `download` on that placeholder fails
    /// -4, `duplicate` cannot copy it into the library, and the "iTunes Store"
    /// source reports no tracks at all. Music will not even produce the
    /// placeholder reliably — the same script made a URL track one minute and
    /// none the next. The other routes out are worse: MusicKit's catalogue
    /// requests need a Team ID with a MusicKit service behind them, which an
    /// ad-hoc signed build has no way to hold, and the streams are FairPlay, so
    /// nothing outside Music can decode them.
    ///
    /// What is left is the plus button, and it is one click. So the page is
    /// opened for that click and the library is watched; the moment the song
    /// lands, it starts. It is also the outcome worth having — once added it is
    /// a library track like any other, so it can be queued, reordered,
    /// requested and lyric-synced, none of which a stream could be.
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

    /// Polls rather than waits on a notification: Music posts nothing when a
    /// track is added to the library. Every 1.5s for two minutes is 80 searches
    /// at 0.18s each, which is cheap next to how long it takes someone to find
    /// the button.
    private func watchForArrival(of track: CatalogTrack) {
        awaitTask?.cancel()
        awaiting = track
        awaitTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { return }
                guard let browser = await MainActor.run(body: { self.model?.browser }) else { break }
                let hits = (try? await browser.searchLibrary(Self.searchTerm(for: track))) ?? []
                guard !Task.isCancelled else { return }
                if let match = hits.first(where: { Self.isSame($0, as: track) }),
                   let id = match.databaseID {
                    try? await browser.playNow(databaseID: id)
                    Diagnostics.log("catalogue: \(track.name) added to the library, started it")
                    await MainActor.run {
                        self.awaiting = nil
                        self.awaitTask = nil
                    }
                    return
                }
            }
            Diagnostics.log("catalogue: gave up waiting for \(track.name)")
            await MainActor.run {
                self?.awaiting = nil
                self?.awaitTask = nil
            }
        }
    }

    /// The store's title carries credits the library copy may not: the store
    /// calls it "Monsters (feat. Demi Lovato & blackbear)" where the library has
    /// "Monsters (feat. blackbear)", and searching the library for the longer
    /// string finds nothing at all. Searching for the title alone found it, and
    /// `isSame` still has the artist and the running time to judge on.
    private static func searchTerm(for track: CatalogTrack) -> String {
        let stripped = outsideBrackets(track.name).trimmingCharacters(in: .whitespaces)
        return stripped.count >= 2 ? stripped : track.name
    }

    /// Music's copy of a track is rarely character-identical to the store's —
    /// "(feat. …)" comes and goes, and so does punctuation — so the comparison
    /// is on the bare title plus a shared artist word plus the running time.
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

    /// Search hits carry a database ID rather than a position in a playlist,
    /// so they start through `playNow` instead of the playlist path.
    func playHit(_ track: LibraryTrack) {
        if let id = track.databaseID {
            model?.performOnBrowser { try await $0.playNow(databaseID: id) }
        } else {
            // Spotify results carry a URI instead.
            model?.performOnBrowser { try await $0.play(track) }
        }
    }

    func play(_ track: LibraryTrack) {
        model?.performOnBrowser { try await $0.play(track) }
    }

    /// Cover for a playlist, taken from its first track. Loaded once, and only
    /// when a card actually appears.
    func cover(for playlist: LibraryPlaylist) {
        guard covers[playlist.index] == nil,
              !coversInFlight.contains(playlist.index),
              let browser = model?.browser, browser.canBrowseLibrary else { return }
        coversInFlight.insert(playlist.index)
        let asked = generation
        let probe = LibraryTrack(id: "cover-\(playlist.index)", name: "", artist: "",
                                 duration: 0, playlistIndex: playlist.index,
                                 trackIndex: 1, uri: nil, playlistID: playlist.persistentID)
        Task { [weak self] in
            let data = await browser.artwork(for: probe)
            await MainActor.run {
                guard let self, self.generation == asked else { return }
                self.coversInFlight.remove(playlist.index)
                if let data, let image = NSImage(data: data) {
                    self.covers[playlist.index] = image
                }
            }
        }
    }
}
