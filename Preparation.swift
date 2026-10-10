import Foundation

/// A playlist looked up ahead of a night: every song's lyrics, key and tempo
/// fetched now and kept on the Mac — the lyrics in their cache, the key and
/// tempo in theirs — so each is there the moment its song starts, whether or
/// not the venue's Wi-Fi is; and the songs that need something done listed
/// while there's still time to do it.
///
/// It runs on with its sheet closed, and goes through the same lookups as a
/// song starting, so what it finds is exactly what the night will show.
@MainActor
final class Preparation: ObservableObject {

    static let shared = Preparation()

    enum Lyrics: Equatable {
        case waiting
        case timed
        case timedByYou
        /// Words with no timing: they need timing by hand.
        case untimed
        case instrumental
        case none
        /// LRCLIB couldn't be reached: worth trying again.
        case unreachable
    }

    struct Song: Identifiable, Equatable {
        let track: LibraryTrack
        var lyrics: Lyrics = .waiting
        /// Key and tempo as they'll be sent, a key set by hand included.
        var analysis: TrackAnalysis?
        var keySetByHand = false
        /// Whether the key will be there without the internet: set by hand,
        /// or found by the services and kept. One only the preview gave is
        /// worked out again as the song plays.
        var keyKept = false
        var difficulty: Difficulty?
        var finished = false

        var id: String { track.id }

        var needsAttention: Bool {
            guard finished else { return false }
            return [.untimed, .none, .unreachable].contains(lyrics) || analysis?.key == nil
        }
    }

    /// The playlist the sheet is open for.
    @Published var shown: LibraryPlaylist?
    @Published private(set) var playlist: LibraryPlaylist?
    @Published private(set) var songs: [Song] = []
    @Published private(set) var running = false
    @Published private(set) var failure: String?

    private var task: Task<Void, Never>?
    /// Which run is current: a stopped one finishing late changes nothing.
    private var run = 0

    /// Songs looked up at once: quick, without crowding LRCLIB and the rest.
    private static let together = 3

    var finishedCount: Int { songs.filter(\.finished).count }
    var attentionCount: Int { songs.filter(\.needsAttention).count }

    func prepare(_ playlist: LibraryPlaylist, with browser: MusicBrowser, source: MusicSource) {
        task?.cancel()
        run += 1
        let thisRun = run
        self.playlist = playlist
        songs = []
        failure = nil
        running = true
        Diagnostics.log("prepare: \(playlist.name)")
        task = Task {
            defer { if run == thisRun { running = false } }
            let tracks: [LibraryTrack]
            do {
                tracks = try await browser.tracks(in: playlist)
            } catch {
                failure = error.localizedDescription
                return
            }
            guard !Task.isCancelled else { return }
            songs = tracks.map { Song(track: $0) }
            if tracks.isEmpty { failure = "This playlist is empty." }

            await withTaskGroup(of: (Int, Lyrics, TrackAnalysis?, Bool)?.self) { group in
                var next = 0
                func start() {
                    guard next < tracks.count else { return }
                    let index = next, track = tracks[index]
                    next += 1
                    group.addTask { await Self.lookUp(track, source: source).map { (index, $0.0, $0.1, $0.2) } }
                }
                for _ in 0..<Self.together { start() }
                for await outcome in group {
                    guard !Task.isCancelled else { continue }
                    if let (index, lyrics, analysis, kept) = outcome {
                        record(index, lyrics, analysis, keyKept: kept, source: source)
                    }
                    start()
                }
            }
            guard !Task.isCancelled else { return }
            Diagnostics.log("prepare: \(playlist.name) — \(songs.count) songs, \(attentionCount) to look at")
        }
    }

    func stop() {
        task?.cancel()
        run += 1
        running = false
    }

    private func record(_ index: Int, _ lyrics: Lyrics, _ found: TrackAnalysis?, keyKept: Bool,
                        source: MusicSource) {
        guard songs.indices.contains(index) else { return }
        var song = songs[index]
        song.keyKept = keyKept
        var analysis = found ?? TrackAnalysis()
        if let id = Self.playerTrack(song.track, source: source)?.trackID {
            if let key = Self.savedKey[id] {
                analysis.key = key
                song.keySetByHand = true
                song.keyKept = true
            }
            if let tempo = Self.savedTempo[id] { analysis.tempo = tempo }
        }
        song.lyrics = lyrics
        song.analysis = analysis.isEmpty ? nil : analysis
        song.difficulty = SongInfo.difficulty(song.track.name, song.track.artist)
        song.finished = true
        songs[index] = song
    }

    /// One song, as if it had just started: its lyrics and its key and tempo,
    /// each kept where playing it will look first.
    nonisolated private static func lookUp(_ track: LibraryTrack,
                                           source: MusicSource) async -> (Lyrics, TrackAnalysis?, Bool)? {
        guard let playing = playerTrack(track, source: source) else { return (.none, nil, false) }
        async let lyrics = LyricsProvider.shared.lookup(playing)
        async let analysis = AnalysisProvider.shared.analysis(for: playing)
        let ((result, reached), found) = await (lyrics, analysis)
        guard !Task.isCancelled else { return nil }
        let status: Lyrics
        switch result {
        case .synced(let lines):
            // Rated now, as playing it would, so guests see it when choosing.
            if let rated = Difficulty.rate(lines: lines, tempo: found?.tempo) {
                await MainActor.run { SongInfo.setDifficulty(rated, track.name, track.artist) }
            }
            status = await LyricsProvider.shared.hasUserTiming(trackID: playing.trackID) ? .timedByYou : .timed
        case .plain:        status = .untimed
        case .instrumental: status = .instrumental
        case .notFound:     status = reached ? .none : .unreachable
        }
        let kept = await AnalysisProvider.shared.saved(playing)?.key != nil
        return (status, found, kept)
    }

    /// The song as its player will report it — the same ID, so what's found
    /// now is what's found then.
    nonisolated static func playerTrack(_ track: LibraryTrack, source: MusicSource) -> PlayerTrack? {
        let uri: String
        switch source {
        case .spotify:
            guard let spotify = track.uri else { return nil }
            uri = spotify
        case .appleMusic:
            uri = track.persistentID.flatMap { $0.isEmpty ? nil : "am:\($0)" } ?? "am:\(track.name)-\(track.artist)"
        }
        return PlayerTrack(uri: uri, name: track.name, artist: track.artist,
                           album: track.album ?? "", duration: track.duration, artworkURL: nil)
    }

    #if DEBUG
    /// For checking the sheet's layout: a run's results, as given.
    func show(_ playlist: LibraryPlaylist, songs: [Song], running: Bool = false) {
        self.playlist = playlist
        self.songs = songs
        self.running = running
    }
    #endif

    /// The per-song values set by hand, under the keys `KaraokeModel` saves.
    private static let savedKey = PerSongSetting<String>("trackManualKeys")
    private static let savedTempo = PerSongSetting<Double>("trackManualTempos")
}
