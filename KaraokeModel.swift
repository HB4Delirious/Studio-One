import AppKit
import QuartzCore

enum LyricsState: Equatable {
    case idle
    case loading
    case synced
    case plain(String)
    case instrumental
    case missing
}

/// Everything about the song playing: which player, where in the song, its
/// lyrics, key and tempo, and the corrections made to them — and sending the
/// key and tempo on to Logic.
@MainActor
final class KaraokeModel: ObservableObject {

    enum ConnectionState: Equatable {
        case checking
        case ready
        case playerNotRunning
        case permissionDenied
        case failed(String)
    }

    // MARK: - Player

    /// Which player is followed. Switching rebuilds the controller live.
    @Published var musicSource: MusicSource = {
        UserDefaults.standard.string(forKey: MusicSource.defaultsKey).flatMap(MusicSource.init(rawValue:)) ?? .spotify
    }()
    @Published private(set) var connection: ConnectionState = .checking
    @Published private(set) var track: PlayerTrack?
    @Published private(set) var playerState: PlaybackState = .stopped
    /// One line for the user: the last error, or what just happened.
    @Published var status: String?

    /// Smoothed between polls; not itself published (see `pausedMoves`).
    let clock = PlaybackClock()

    /// Bumped when the position moves while paused. Playing, the lyric view
    /// redraws every frame; paused it redraws only when told.
    @Published private(set) var pausedMoves = 0

    var isPlaying: Bool { playerState == .playing }
    var browser: MusicBrowser? { controller as? MusicBrowser }
    var requestQueue: RequestQueue? { controller as? RequestQueue }

    // MARK: - Lyrics

    @Published private(set) var lines: [LyricLine] = []
        { didSet { lyricsRevision &+= 1 } }
    @Published private(set) var lyricsState: LyricsState = .idle
        { didSet { lyricsRevision &+= 1 } }
    /// Bumped whenever the lyrics change — loaded, found on a second try,
    /// looked up again, timed by hand — so phones following them know to
    /// fetch them again for the same song.
    private(set) var lyricsRevision = 0
    /// Whether the lyrics showing were timed by hand here.
    @Published private(set) var lyricsTimedByYou = false
    /// While the timing sheet takes taps; the Playback menu gives up its bare
    /// Space shortcut meanwhile.
    @Published var isTimingLyrics = false
    @Published private(set) var sharingTiming = false
    /// Where the beat grid sits, estimated once per song.
    @Published private(set) var beatOffset: Double = 0

    /// Sync trim in milliseconds, saved per song. Positive runs the lyrics
    /// ahead of the music.
    @Published var offsetMilliseconds: Double = 0 {
        didSet {
            // Every nudge comes through here, a dial spun hard included.
            // (Assigning inside didSet doesn't call it again.)
            let clamped = min(Self.maxOffset, max(-Self.maxOffset, offsetMilliseconds))
            if clamped != offsetMilliseconds { offsetMilliseconds = clamped }
            if let id = track?.trackID { Saved.offset[id] = offsetMilliseconds }
        }
    }
    static let maxOffset: Double = 10_000

    /// The output device's latency, measured and applied automatically.
    @Published private(set) var automaticLatencyMilliseconds: Double = 0

    /// Where the player's playhead is — for the position bar.
    var playbackPosition: Double { clock.position }

    /// Where the lyrics should be: the playhead less the output's latency,
    /// plus the sync trim.
    var lyricPosition: Double {
        clock.position + (offsetMilliseconds - automaticLatencyMilliseconds) / 1000
    }

    /// What is being heard right now, for tapping lyrics in time.
    var heardPosition: Double {
        max(0, clock.position - automaticLatencyMilliseconds / 1000)
    }

    // MARK: - Key and tempo

    @Published private(set) var analysis: TrackAnalysis?

    /// Typed in, or nudged from the Stream Deck or remote. Saved per song, and
    /// sent straight to Logic.
    @Published var manualKey: String? {
        didSet {
            guard !restoringTrack else { return }
            if let id = track?.trackID { Saved.key[id] = manualKey }
            publishToLogic()
        }
    }
    @Published var manualTempo: Double? {
        didSet {
            guard !restoringTrack else { return }
            if let id = track?.trackID { Saved.tempo[id] = manualTempo }
            publishToLogic()
        }
    }

    /// ×2 or ÷2 for a source that read the song at half or double time — the
    /// only tempo error large enough to hear. Saved per song.
    @Published var tempoMultiplier: Double = 1 {
        didSet {
            guard !restoringTrack else { return }
            if let id = track?.trackID { Saved.tempoMultiplier[id] = tempoMultiplier }
            publishToLogic()
            refreshBeatOffset()
        }
    }

    var hasManualValues: Bool { manualKey != nil || manualTempo != nil }

    /// Key and tempo as shown and sent. Values typed in win outright; ×2 and
    /// ÷2 apply only to what a source reported.
    var publishedAnalysis: TrackAnalysis? {
        var result = analysis ?? TrackAnalysis()
        if let manualKey { result.key = manualKey }
        if let manualTempo {
            result.tempo = manualTempo
        } else if let tempo = result.tempo {
            result.tempo = tempo * tempoMultiplier
        }
        return result.isEmpty ? nil : result
    }

    static let copyOnMissKey = "copyTitleWhenUnknown"

    // MARK: - Around the song

    /// Colours from the cover; empty falls back to the theme.
    @Published private(set) var palette: [PaletteColor] = []
    /// The cover, for players that give image data rather than a URL.
    @Published private(set) var localArtwork: NSImage?
    /// `coverImage()`'s last answer, for the song it was for — nil when
    /// there was none, so a miss isn't asked again.
    private var coverCache: (uri: String, image: NSImage?)?
    /// The fetch under way, shared by everyone asking meanwhile.
    private var coverFetch: (uri: String, task: Task<NSImage?, Never>)?
    /// The song after this one in the queue, for the lyrics screen.
    @Published private(set) var nextUp: LibraryTrack?
    /// How hard this song is to sing, once its lyrics are known (see `SongInfo`).
    @Published private(set) var difficulty: Difficulty?
    /// The host's own note on this song; never shown to guests.
    @Published private(set) var songNote: String?
    /// The break between songs under way, if any (see `BreakMode`).
    @Published private(set) var intermission: Intermission?
    /// A fade out under way (see `FadeOut`).
    @Published private(set) var fading = false
    /// The house playlist is playing between singers (see `HouseMusic`).
    @Published private(set) var fillerPlaying = false
    /// "Let It Play": this play of the song goes past the time limit.
    @Published private(set) var limitWaived = false

    // MARK: - Private state

    private var controller: MusicPlayer?
    private let pollInterval: TimeInterval = 0.5
    private var pollTimer: Timer?
    private var playbackObserver: NSObjectProtocol?
    /// A poll still waiting on its Apple Event; the next waits its turn.
    private var polling = false
    private var lastTrackURI: String?

    private var lyricsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?

    /// Seeks not yet answered, and when the last one was: a poll sampled
    /// before a seek landed still says where the song was.
    private var seeksInFlight = 0
    private var positionTrustedFrom: CFTimeInterval = 0

    /// While a song's saved values are put back one by one, so they aren't
    /// each sent to Logic mixed with the last song's. The analysis landing
    /// sends them once.
    private var restoringTrack = false
    /// From a song change until its analysis lands: no key *yet* is not no
    /// key, so the tuners aren't bypassed for it.
    private var analysisPending = false
    private var recordedThisPlay = false
    /// The pause at this song's end is scheduled; and the break's own timer.
    private var breakArmed = false
    /// Which arming a scheduled pause belongs to: an older one, overtaken by
    /// a seek or a pause, leaves the newer alone.
    private var breakArming = 0
    private var breakTimer: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    /// What stopped a fade early, done before the volume goes back up.
    private var fadeThen: FadeStop?

    /// What stopped a fade early — pressed during it, or as it reached silence.
    enum FadeStop { case pause, next, previous }
    /// Where in the song the time limit's fade starts, once past the limit.
    private var limitFadeAt: Double?
    /// The song to come back to after house music — nil with nothing queued.
    private var fillerResume: LibraryTrack?
    /// The volume to put back after house music.
    private var fillerVolume: Int?
    /// House music about to start, after the cheer has been heard.
    private var fillerStart: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Called by both windows as they appear; only the first call does anything.
    func start() {
        guard pollTimer == nil else { return }

        Diagnostics.startSession()
        ControlServer.shared.start(model: self)
        PluginDisplay.shared.start()
        PluginDisplay.check.start()   // Only once turned on in Settings.
        LightShow.shared.start(model: self)
        Performances.shared.start(model: self)
        RequestServer.shared.configureRemote(model: self)
        _ = KeyCheck.shared
        Task.detached(priority: .utility) {
            LogicBackup.backUpIfChanged()
            for swallower in LogicAssignments.swallowers() { Diagnostics.log("logic: " + swallower.warning) }
            for wrong in LogicAssignments.wrongPorts() { Diagnostics.log("logic: " + wrong.warning) }
        }
        guard connect() else { return }
        MIDIBridge.shared.start()
        // Warmed off the launch path: its keychain read can raise a prompt.
        Task.detached(priority: .utility) { await SpotifyAPI.shared.warm() }

        // Spotify announces every play, pause, seek and track change; taken
        // as a cue to poll now rather than read for its contents.
        playbackObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }

        poll()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // .common keeps polling while a slider is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Follows the other player, without relaunching.
    func changeSource(to newSource: MusicSource) {
        guard newSource != musicSource else { return }
        Diagnostics.log("source: switching to \(newSource.displayName)")
        musicSource = newSource
        UserDefaults.standard.set(newSource.rawValue, forKey: MusicSource.defaultsKey)

        // The request line fills an Apple Music playlist; left running, guests
        // would go on adding to a queue nobody is playing.
        if RequestServer.shared.running, newSource != .appleMusic {
            RequestServer.shared.stop(because: "Stopped: requests need Apple Music as the source.")
        }

        lastTrackURI = nil
        track = nil
        handleTrackChange(nil)
        connection = .checking
        if connect() { poll() }
    }

    /// Builds the controller for `musicSource`, and asks macOS once for
    /// permission to script that player.
    private func connect() -> Bool {
        do {
            controller = try musicSource == .spotify ? SpotifyController() : AppleMusicController()
            Diagnostics.log("\(musicSource.displayName) controller ready")
        } catch {
            Diagnostics.log("ERROR controller init failed: \(error.localizedDescription)")
            controller = nil
            connection = .failed(error.localizedDescription)
            return false
        }
        // Blocks until the consent dialog is answered, so never on the main
        // thread: there it froze the app before it drew.
        let bundleID = musicSource.bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            PlayerScripts.automationPermission(for: bundleID, prompt: true)
        }
        return true
    }

    // MARK: - Polling

    private func poll() {
        guard let controller, !polling else { return }
        polling = true
        Task {
            defer { polling = false }
            // An answer from a player switched away from meanwhile is dropped;
            // the timer asks the new one half a second later.
            do {
                let snapshot = try await controller.snapshot()
                let latency = await AudioLatency.measuredMilliseconds()
                guard self.controller === controller else { return }
                apply(snapshot: snapshot, latency: latency)
            } catch {
                guard self.controller === controller else { return }
                handle(error)
            }
        }
    }

    /// Every published value here is assigned only when it changes: an
    /// assignment rebuilds every view watching the model, equal or not, and
    /// twice a second that alone kept an idle app at 12–15% CPU.
    private func apply(snapshot: PlayerSnapshot, latency: Double) {
        if connection != .ready {
            Diagnostics.log("connection: ready")
            status = nil        // whatever was wrong while the player was away isn't now
            connection = .ready
            restoreVolumeAfterCutFade()
        }

        // A song that played to its end with nothing after it: the queue ran
        // dry. Judged before the snapshot replaces what was playing.
        let ranDry = isPlaying && snapshot.state != .playing && intermission == nil && !fillerPlaying
            && !fading && track.map { $0.duration - clock.position < 3 } == true

        // `track` before the song change, which saves under the current track.
        let changed = snapshot.track?.uri != lastTrackURI
        lastTrackURI = snapshot.track?.uri
        if track != snapshot.track { track = snapshot.track }
        if changed { handleTrackChange(snapshot.track) }

        if playerState != snapshot.state { playerState = snapshot.state }
        if ranDry, HouseMusic.isEnabled, HouseMusic.whenEmpty {
            Diagnostics.log("house music: the queue ran out")
            startFiller(resume: nil)
        }

        if abs(latency - automaticLatencyMilliseconds) > 1 {
            Diagnostics.log("output latency: \(Int(latency)) ms (applied automatically)")
            automaticLatencyMilliseconds = latency
        }

        let playing = snapshot.state == .playing
        if seeksInFlight > 0 || snapshot.sampledAt < positionTrustedFrom {
            if playing != clock.isPlaying { clock.reset(to: clock.position, playing: playing) }
        } else {
            let before = clock.position
            clock.ingest(sample: snapshot.position, sampledAt: snapshot.sampledAt, playing: playing)
            recordIfSung()
            armBreakIfEnding()
            checkTimeLimit()
            if !playing, abs(clock.position - before) > 0.05 { clockMoved() }
        }
    }

    private func clockMoved() {
        if !clock.isPlaying { pausedMoves &+= 1 }
    }

    private func handle(_ error: Error) {
        let next: ConnectionState
        switch error as? PlayerError {
        case .notRunning:    next = .playerNotRunning
        case .notAuthorized: next = .permissionDenied
        default:             next = .failed(error.localizedDescription)
        }
        if connection != next {
            Diagnostics.log("connection: \(next) — \(error.localizedDescription)")
            connection = next
        }
    }

    // MARK: - Song change

    private func handleTrackChange(_ newTrack: PlayerTrack?) {
        PartyGames.shared.songChanged(to: newTrack)
        // A new song, however it came, ends any break, and any fade.
        // Not house music's songs, though: they play during it.
        if intermission != nil, !fillerPlaying { finishIntermission() }
        breakArmed = false
        stopFade()
        limitWaived = false
        limitFadeAt = nil
        lyricsTask?.cancel()
        analysisTask?.cancel()
        paletteTask?.cancel()
        status = nil
        lines = []
        analysis = nil
        palette = []
        localArtwork = nil      // or the last song's cover stands in until the new one loads
        clock.reset(to: 0, playing: false)

        guard let newTrack else {
            Diagnostics.log("track: none")
            difficulty = nil
            songNote = nil
            lyricsState = .idle
            restoringTrack = true
            offsetMilliseconds = 0
            tempoMultiplier = 1
            manualKey = nil
            manualTempo = nil
            restoringTrack = false
            analysisPending = false
            MIDIBridge.shared.stopClock()
            return
        }

        let id = newTrack.trackID
        Diagnostics.log("track: \(newTrack.name) — \(newTrack.artist) [\(id)] \(Int(newTrack.duration))s")
        difficulty = SongInfo.difficulty(newTrack.name, newTrack.artist)
        songNote = SongInfo.note(newTrack.name, newTrack.artist)
        Diagnostics.log("  sync: trim \(Int(Saved.offset[id] ?? 0)) ms + auto -\(Int(automaticLatencyMilliseconds)) ms")

        paletteTask = Task {
            if newTrack.artworkURL == nil, browser != nil {
                let image = await coverImage()
                guard !Task.isCancelled, track?.uri == newTrack.uri else { return }
                localArtwork = image
                palette = image.map { PaletteProvider.shared.palette(for: $0) } ?? []
            } else {
                let colours = await PaletteProvider.shared.palette(for: newTrack)
                guard !Task.isCancelled, track?.uri == newTrack.uri else { return }
                palette = colours
            }
        }

        analysisPending = true
        analysisTask = Task {
            let result = await AnalysisProvider.shared.analysis(for: newTrack)
            guard !Task.isCancelled, track?.uri == newTrack.uri else { return }
            analysis = result
            analysisPending = false
            refreshBeatOffset()
            Diagnostics.log("analysis: " + (result.map(Self.describe) ?? "nothing from any source"))
            publishToLogic()
            copyTitleIfUnknown(newTrack)

            // Asked once more a little later if nothing came back: a failed
            // lookup isn't cached, and a song with no key bypasses the tuners.
            guard result == nil else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled,
                  let again = await AnalysisProvider.shared.analysis(for: newTrack),
                  track?.uri == newTrack.uri, analysis == nil else { return }
            analysis = again
            refreshBeatOffset()
            Diagnostics.log("analysis (second try): " + Self.describe(again))
            if status?.hasPrefix("No key or tempo found") == true { status = nil }
            publishToLogic()
        }

        restoringTrack = true
        offsetMilliseconds = Saved.offset[id] ?? 0
        tempoMultiplier = Saved.tempoMultiplier[id] ?? 1
        manualKey = Saved.key[id]
        manualTempo = Saved.tempo[id]
        restoringTrack = false

        refreshNextUp()
        recordedThisPlay = false
        // Per-song plug-in settings depend only on the song, so they don't
        // wait for the analysis.
        if !fillerPlaying {
            MIDIBridge.shared.sendSongControls(SongControl.messages(trackID: id), sweep: true, label: "Song settings")
        }
        loadLyrics(for: newTrack)
    }

    /// Sends the song's key and tempo to Logic — the one way they go out.
    func publishToLogic() {
        // House music's keys aren't the singers': the tuners stay as they are.
        guard !fillerPlaying else { return }
        MIDIBridge.shared.publish(publishedAnalysis, lookupPending: analysisPending)
    }

    /// Whenever the lyrics or the tempo land — either can be first.
    private func refreshBeatOffset() {
        rateDifficulty()
        guard let tempo = publishedAnalysis?.tempo, !lines.isEmpty else {
            beatOffset = 0
            return
        }
        beatOffset = LRCParser.beatOffset(lines: lines, bpm: tempo)
        Diagnostics.log("  beat grid: \(String(format: "%.0f", tempo)) bpm, offset \(Int(beatOffset * 1000)) ms")
    }

    /// Whenever the lyrics or the tempo land — the same moments as the beat
    /// grid — the song's difficulty is worked out again and kept.
    private func rateDifficulty() {
        guard lyricsState == .synced, let track,
              let rated = Difficulty.rate(lines: lines, tempo: publishedAnalysis?.tempo) else { return }
        SongInfo.setDifficulty(rated, track.name, track.artist)
        if difficulty != rated { difficulty = rated }
    }

    /// The host's note on the song playing.
    func setSongNote(_ note: String) {
        guard let track else { return }
        SongInfo.setNote(note, track.name, track.artist)
        songNote = SongInfo.note(track.name, track.artist)
    }

    /// With no key or tempo from any source, the next step is looking the
    /// song up by hand, so its name goes on the clipboard.
    private func copyTitleIfUnknown(_ track: PlayerTrack) {
        let enabled = UserDefaults.standard.object(forKey: Self.copyOnMissKey) as? Bool ?? true
        guard enabled, publishedAnalysis == nil else { return }
        let text = "\(track.name) - \(track.artist)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "No key or tempo found — “\(text)” copied to the clipboard."
    }

    private static func describe(_ analysis: TrackAnalysis) -> String {
        "key=\(analysis.key ?? "-") tempo=\(analysis.tempo.map { String(format: "%.2f", $0) } ?? "-")"
            + (analysis.halfTimeSuspect ? " HALF-TIME SUSPECT" : "")
    }

    /// The playing song's cover, for the Stream Deck and phones: the one
    /// already loaded, else fetched — from its URL, or from the player — once
    /// per song. Nil only when there's none to be had.
    func coverImage() async -> NSImage? {
        guard let track else { return nil }
        if let localArtwork { return localArtwork }
        if let coverCache, coverCache.uri == track.uri { return coverCache.image }
        // One fetch per song, however many ask at once: the deck, the remote,
        // every phone, and the cover for the app's own colours.
        if let coverFetch, coverFetch.uri == track.uri { return await coverFetch.task.value }
        let browser = browser
        let task = Task { () -> NSImage? in
            if let url = track.artworkURL {
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
                return NSImage(data: data)
            }
            return await browser?.currentArtwork().flatMap(NSImage.init(data:))
        }
        coverFetch = (track.uri, task)
        let image = await task.value
        if coverFetch?.uri == track.uri { coverFetch = nil }
        // Not kept unless it's still this song: the fetch can outlast a skip.
        guard self.track?.uri == track.uri else { return nil }
        coverCache = (track.uri, image)
        return image
    }

    /// Re-read on every song change, and when a request changes the queue.
    func refreshNextUp() {
        // During house music, what's next is the song noted to come back to.
        if fillerPlaying {
            if nextUp != fillerResume { nextUp = fillerResume }
            return
        }
        guard let browser, browser.canBrowseLibrary, let playing = track?.uri else {
            if nextUp != nil { nextUp = nil }
            return
        }
        Task {
            let queue = (try? await browser.upNext(limit: 2)) ?? nil
            guard track?.uri == playing else { return }
            let next = queue?.tracks.dropFirst().first
            if nextUp != next { nextUp = next }
        }
    }

    /// Into the night's history once it has played thirty seconds, which
    /// leaves skips out.
    private func recordIfSung() {
        guard !recordedThisPlay, !fillerPlaying, isPlaying, let track, clock.position >= 30 else { return }
        recordedThisPlay = true
        Setlists.shared.record(SetlistEntry(
            at: Date(),
            name: track.name,
            artist: track.artist,
            uri: track.uri,
            source: musicSource.rawValue,
            singer: RequestServer.shared.requester(name: track.name, artist: track.artist),
            key: publishedAnalysis?.key,
            tempo: publishedAnalysis?.tempo))
    }

    // MARK: - Lyrics loading

    private func loadLyrics(for newTrack: PlayerTrack) {
        lyricsTask?.cancel()
        lines = []
        lyricsState = .loading
        lyricsTimedByYou = false
        lyricsTask = Task {
            let result = await LyricsProvider.shared.lyrics(for: newTrack)
            let mine = await LyricsProvider.shared.hasUserTiming(trackID: newTrack.trackID)
            guard !Task.isCancelled, track?.uri == newTrack.uri else { return }
            lyricsTimedByYou = mine
            apply(result)

            // Asked once more a little later if nothing came back: a lookup
            // that couldn't reach LRCLIB isn't remembered, while a song LRCLIB
            // really doesn't have answers from memory.
            guard case .notFound = result else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            let again = await LyricsProvider.shared.lyrics(for: newTrack)
            if case .notFound = again { return }
            guard track?.uri == newTrack.uri, lyricsState == .missing else { return }
            Diagnostics.log("lyrics: found on a second try")
            apply(again)
        }
    }

    private func apply(_ result: LyricsResult) {
        switch result {
        case .synced(let parsed):
            Diagnostics.log("lyrics: synced, \(parsed.count) lines")
            lines = parsed
            lyricsState = .synced
            refreshBeatOffset()
        case .plain(let text):
            Diagnostics.log("lyrics: plain only (untimed)")
            lines = []
            lyricsState = .plain(text)
        case .instrumental:
            Diagnostics.log("lyrics: instrumental")
            lines = []
            lyricsState = .instrumental
        case .notFound:
            Diagnostics.log("lyrics: not found")
            lines = []
            lyricsState = .missing
        }
    }

    /// Fetches the lyrics again — only the lyrics, so the clock and the key
    /// sent to Logic are left alone.
    func reloadLyrics() {
        guard let track else { return }
        Task {
            await LyricsProvider.shared.invalidate(trackID: track.trackID)
            guard self.track?.uri == track.uri else { return }
            loadLyrics(for: track)
        }
    }

    /// The line to light up at `position`, or nil before the first.
    func activeIndex(at position: Double) -> Int? {
        var low = 0, high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    // MARK: - Transport

    /// During a break, Play — here, on the Stream Deck or the remote — starts
    /// the next song rather than the last second of the one that ended.
    func togglePlayback() {
        if intermission != nil { return endIntermission() }
        if fading { return stopFade(then: .pause) }
        perform { try await $0.playPause() }
    }
    func nextTrack() {
        if intermission != nil { return endIntermission() }
        if fading { return stopFade(then: .next) }
        perform { try await $0.next() }
    }
    func previousTrack() {
        if intermission != nil { finishIntermission() }
        if fading { return stopFade(then: .previous) }
        perform { try await $0.previous() }
    }

    // MARK: - Between songs

    /// Pauses just before a song ends on its own, for the break: scheduled to
    /// the moment, since polls are half a second apart and the next song
    /// mustn't be heard starting.
    private func armBreakIfEnding() {
        // Back from the end — a seek, Previous restarting it, repeat-one —
        // the song's end can be armed again.
        if breakArmed, let track, track.duration - clock.position >= 2 {
            breakArmed = false
            breakArming &+= 1
        }
        guard !breakArmed, !fading, !fillerPlaying, intermission == nil, BreakMode.current != .off, isPlaying,
              let track, track.duration > 45 else { return }
        let remaining = track.duration - clock.position
        guard remaining > 0, remaining < 2 else { return }
        breakArmed = true
        breakArming &+= 1
        let arming = breakArming
        let uri = track.uri
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining - 0.45)) { [weak self] in
            guard let self, self.track?.uri == uri, self.breakArming == arming else { return }
            guard self.isPlaying, self.intermission == nil,
                  track.duration - self.clock.position < 1.2 else {
                // Paused or moved meanwhile: armed again by the next poll that
                // finds it playing near the end.
                self.breakArmed = false
                return
            }
            self.beginIntermission(after: track)
        }
    }

    /// `pausing` is false after a fade, which has paused already.
    private func beginIntermission(after track: PlayerTrack, pausing: Bool = true) {
        if pausing { perform { try await $0.playPause() } }
        clock.reset(to: clock.position, playing: false)
        let mode = BreakMode.current
        let pause = Intermission(
            endedName: track.name,
            endedArtist: track.artist,
            endedURI: track.uri,
            singer: RequestServer.shared.requester(name: track.name, artist: track.artist),
            started: Date(),
            endsAt: mode.seconds.map { Date().addingTimeInterval($0) })
        intermission = pause
        Diagnostics.log("break: after \(track.name)" + (mode.seconds.map { ", \(Int($0)) s" } ?? ", until Play"))
        Applause.shared.measure(for: pause)
        scheduleBreakEnd()
        // House music once the cheer's been heard, noting first what's next.
        if HouseMusic.isEnabled, HouseMusic.duringBreaks {
            let delay = Applause.isEnabled ? Applause.window + 0.5 : 1.0
            fillerStart?.cancel()
            fillerStart = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.intermission != nil else { return }
                let resume = await self.browser?.resumePoint()
                guard !Task.isCancelled, self.intermission != nil else { return }
                self.startFiller(resume: resume)
            }
        }
    }

    private func scheduleBreakEnd() {
        breakTimer?.cancel()
        guard let endsAt = intermission?.endsAt else { return }
        breakTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.endIntermission()
        }
    }

    /// A little more time — for a long goodbye, or a slow walk to the mic.
    func extendIntermission(by seconds: Double = 30) {
        guard var pause = intermission else { return }
        pause.endsAt = max(pause.endsAt ?? Date(), Date()).addingTimeInterval(seconds)
        intermission = pause
        scheduleBreakEnd()
    }

    /// The break's over: on to the next song, started if Next left it paused.
    func endIntermission() {
        guard intermission != nil else { return }
        finishIntermission()
        Diagnostics.log("break: over")
        if fillerPlaying {
            // Back to the song noted; with none, house music plays on until a
            // request comes in.
            if fillerResume != nil { Task { await stopFiller(resuming: true) } }
            return
        }
        advance()
    }

    /// On to the next song (or another `step`), started if it's left paused.
    private func advance(by step: @escaping (MusicPlayer) async throws -> Void = { try await $0.next() }) {
        guard let controller else { return }
        Task {
            do {
                try await step(controller)
                poll()
                try await Task.sleep(for: .seconds(1.2))
                if !isPlaying { try await controller.playPause() }
                poll()
            } catch {
                Diagnostics.log("ERROR playback: \(error.localizedDescription)")
                status = error.localizedDescription
            }
        }
    }

    private func finishIntermission() {
        intermission = nil
        breakTimer?.cancel()
        breakTimer = nil
        if !fillerPlaying { fillerStart?.cancel() }
        Applause.shared.stop()
    }

    // MARK: - House music

    /// The house playlist, from a song near its start, at the house level.
    /// `resume` is the song to come back to; nil when nothing is queued.
    private func startFiller(resume: LibraryTrack?) {
        guard HouseMusic.isEnabled, !fillerPlaying, let choice = HouseMusic.playlist, let browser else { return }
        fillerStart = Task { [weak self] in
            guard let self else { return }
            guard let playlist = (try? await browser.playlists())?.first(where: { choice.matches($0) }),
                  let tracks = try? await browser.tracks(in: playlist), !tracks.isEmpty else {
                self.status = "House music: couldn't find the playlist “\(choice.name)”."
                return
            }
            guard !Task.isCancelled, !self.fillerPlaying, let start = await browser.readVolume() else { return }
            // Marked first, so the songs it starts are taken as house music.
            self.fillerPlaying = true
            self.fillerResume = resume
            self.fillerVolume = start
            FadeOut.pendingVolume = start
            self.nextUp = resume
            await browser.setVolume(Int((Double(start) * HouseMusic.level / 100).rounded()))
            // Music queues what follows only from near a playlist's start.
            let pick = tracks[Int.random(in: 0..<min(tracks.count, 40))]
            do {
                try await browser.play(pick)
                Diagnostics.log("house music: \(playlist.name), back to \(resume?.name ?? "the next request")")
            } catch {
                Diagnostics.log("ERROR house music: \(error.localizedDescription)")
                await self.stopFiller(resuming: false)
            }
            self.poll()
        }
    }

    /// Off: paused, the volume put back, then — `resuming` — the song noted.
    private func stopFiller(resuming: Bool) async {
        guard fillerPlaying, let browser, let controller else { return }
        fillerStart?.cancel()
        let target = fillerResume
        if isPlaying { try? await controller.playPause() }
        if let volume = fillerVolume { await browser.setVolume(volume) }
        FadeOut.pendingVolume = nil
        fillerVolume = nil
        fillerResume = nil
        fillerPlaying = false
        Diagnostics.log("house music: off" + (resuming ? ", back to \(target?.name ?? "nothing")" : ""))
        if resuming, let target {
            do { try await browser.play(target) } catch {
                Diagnostics.log("ERROR playback: \(error.localizedDescription)")
                status = "Couldn't go back to “\(target.name)” — start it in the Controls window."
            }
        }
        poll()
    }

    /// From the Controls window: back to the queue now, or just off.
    func endHouseMusic() {
        if intermission != nil { return endIntermission() }
        Task { await stopFiller(resuming: fillerResume != nil) }
    }

    /// A song chosen to play — in Controls, Prepare or on the remote — takes
    /// over from house music.
    func playChosen(_ track: LibraryTrack) {
        Task {
            if fillerPlaying { await stopFiller(resuming: false) }
            performOnBrowser { try await $0.play(track) }
        }
    }

    /// The same, for the remote's play-now by database ID.
    func leaveHouseMusic() async {
        if fillerPlaying { await stopFiller(resuming: false) }
    }

    /// A guest's request: while house music plays with nothing queued, it's
    /// the song to come back to — straight away, or as the break ends.
    func requestArrived(_ track: LibraryTrack) {
        guard fillerPlaying, fillerResume == nil, let music = browser as? AppleMusicController,
              let id = track.databaseID else { return }
        Task {
            guard let playlistID = await music.requestsPlaylistID(), let count = await music.requestCount(),
                  fillerPlaying, fillerResume == nil else { return }
            fillerResume = LibraryTrack(id: "request-\(id)", name: track.name, artist: track.artist,
                                        duration: track.duration, playlistIndex: nil, trackIndex: count,
                                        uri: nil, databaseID: id, playlistID: playlistID)
            nextUp = fillerResume
            if intermission == nil { await stopFiller(resuming: true) }
        }
    }

    // MARK: - Fading out

    /// Takes the song down to silence over `FadeOut.length`, pauses it there
    /// and puts the volume back; then the break, if there is one, or the next
    /// song.
    func fadeOut() {
        guard !fading, !fillerPlaying, intermission == nil, isPlaying, let track, let controller, let browser else { return }
        fading = true
        fadeThen = nil
        let uri = track.uri
        let length = FadeOut.length
        Diagnostics.log("fade: \(track.name), \(Int(length)) s")
        fadeTask = Task {
            // Not a guess: a fade that put back the wrong volume would start
            // the next song too loud.
            guard let start = await browser.readVolume() else {
                fading = false
                fadeTask = nil
                status = "Couldn't read \(musicSource.displayName)'s volume to fade from."
                return
            }
            FadeOut.pendingVolume = start
            // Paced by the clock rather than by steps, since each step waits
            // on the player: the fade takes the time it says.
            let began = Date()
            var done = true, last = start
            while true {
                try? await Task.sleep(for: .milliseconds(80))
                // Stopped (Play, Next, Cancel), or the song ended or was
                // paused some other way: not the fade's to finish.
                guard !Task.isCancelled, self.track?.uri == uri, playerState == .playing else {
                    done = false
                    break
                }
                let progress = min(1, Date().timeIntervalSince(began) / length)
                let level = FadeOut.level(from: start, at: progress)
                if level != last {
                    await browser.setVolume(level)
                    last = level
                }
                if progress >= 1 { break }
            }
            let finished = done && !Task.isCancelled && self.track?.uri == uri
            if finished {
                if isPlaying { try? await controller.playPause() }
                clock.reset(to: clock.position, playing: false)
            }
            // What happens now, decided once: a press during the fade is done
            // while it's still quiet (`now`); the fade's own ending, or a
            // press that came as it reached silence, once the volume is back.
            let pressed = fadeThen
            fadeThen = nil
            var now: ((MusicPlayer) async throws -> Void)?
            var after: (() -> Void)?
            switch (finished, pressed) {
            case (false, .pause?):    now = { try await $0.playPause() }
            case (false, .next?):     now = { try await $0.next() }
            case (false, .previous?): now = { try await $0.previous() }
            case (false, nil):        break
            case (true, .pause?):     break                     // already paused, as asked
            case (true, .next?):      after = { self.advance() }
            case (true, .previous?):  after = { self.advance(by: { try await $0.previous() }) }
            case (true, nil):
                after = {
                    if BreakMode.current != .off {
                        self.beginIntermission(after: track, pausing: false)
                    } else {
                        self.advance()
                    }
                }
            }
            if let now {
                do { try await now(controller) } catch {
                    Diagnostics.log("ERROR playback: \(error.localizedDescription)")
                }
            }
            // Back up, in order after every step of the fade: the player
            // takes these one at a time.
            await browser.setVolume(start)
            FadeOut.pendingVolume = nil
            fading = false
            fadeTask = nil
            poll()
            guard finished, self.track?.uri == uri else {
                Diagnostics.log("fade: stopped, volume back to \(start)")
                return
            }
            Diagnostics.log("fade: done, volume back to \(start)")
            after?()
        }
    }

    /// Stops a fade where it is, does `then` (pause, skip) and puts the
    /// volume back; with nothing to do, just puts it back.
    func stopFade(then action: FadeStop? = nil) {
        guard fading else { return }
        // A later stop with nothing to do (a song change) keeps a press.
        if let action { fadeThen = action }
        fadeTask?.cancel()
    }

    /// This time, the song plays to the end.
    func letItPlay() {
        limitWaived = true
        limitFadeAt = nil
        if fading { stopFade() }
        Diagnostics.log("time limit: let it play")
    }

    /// Whether the time limit will end this song.
    var timeLimitApplies: Bool {
        guard let limit = FadeOut.timeLimit, let track else { return false }
        return !limitWaived && track.duration > limit + FadeOut.grace
    }

    /// Past the limit, the fade waits for the line being sung to end.
    private func checkTimeLimit() {
        guard timeLimitApplies, let limit = FadeOut.timeLimit, !fading, !fillerPlaying, intermission == nil,
              isPlaying else { return }
        let position = clock.position
        guard position >= limit else {
            limitFadeAt = nil      // seeked back before it
            return
        }
        if limitFadeAt == nil {
            limitFadeAt = fadePoint(from: position)
            Diagnostics.log(String(format: "time limit: passed, fading at %.1f s", limitFadeAt ?? position))
        }
        if let at = limitFadeAt, position >= at {
            // Once a play: a fade that can't start (no volume to read) isn't
            // tried again every poll.
            limitFadeAt = .infinity
            fadeOut()
        }
    }

    /// Where the line being sung ends — the next line's start — in the
    /// player's time. Now, between lines, without timed lyrics, or when the
    /// line began long enough ago to have been sung.
    private func fadePoint(from position: Double) -> Double {
        guard lyricsState == .synced else { return position }
        let shift = (offsetMilliseconds - automaticLatencyMilliseconds) / 1000
        let lyricNow = position + shift
        guard let index = activeIndex(at: lyricNow), !lines[index].isBlank,
              lyricNow - lines[index].time < FadeOut.lineSung,
              let next = lines[(index + 1)...].first else { return position }
        return min(next.time - shift, position + FadeOut.lineWait)
    }

    /// A fade cut short by quitting left the player quiet: put it back.
    private func restoreVolumeAfterCutFade() {
        guard let volume = FadeOut.pendingVolume, !fading, !fillerPlaying, let browser else { return }
        Task {
            await browser.setVolume(volume)
            FadeOut.pendingVolume = nil
            Diagnostics.log("fade: volume put back to \(volume) after a fade was cut short")
        }
    }
    func revealPlayer() { controller?.activate() }

    func seek(to seconds: Double) {
        guard let controller else { return }
        clock.reset(to: seconds, playing: isPlaying)
        clockMoved()
        seeksInFlight += 1
        Task {
            do {
                try await controller.seek(to: seconds)
                status = nil
            } catch {
                Diagnostics.log("ERROR transport: \(error.localizedDescription)")
                status = error.localizedDescription
            }
            seeksInFlight -= 1
            positionTrustedFrom = CACurrentMediaTime()
            poll()
        }
    }

    /// To the start of a lyric line, for practising one verse.
    func jump(to line: LyricLine) {
        seek(to: max(0, line.time - offsetMilliseconds / 1000))
    }

    func performOnBrowser(_ action: @escaping (MusicBrowser) async throws -> Void) {
        perform(on: browser, action)
    }

    func performOnRequestQueue(_ action: @escaping (RequestQueue) async throws -> Void) {
        perform(on: requestQueue, action)
    }

    private func perform(_ action: @escaping (MusicPlayer) async throws -> Void) {
        perform(on: controller, action)
    }

    /// Runs something against the player, putting any failure in the status
    /// line, and polls straight after so the result shows at once.
    private func perform<Target>(on target: Target?, _ action: @escaping (Target) async throws -> Void) {
        guard let target else { return }
        Task {
            do {
                try await action(target)
                status = nil
                poll()
            } catch {
                Diagnostics.log("ERROR playback: \(error.localizedDescription)")
                status = error.localizedDescription
            }
        }
    }

    // MARK: - Corrections

    /// Moves the key the app believes in — not the audio, which is a finished
    /// mix. From nothing it starts at C, since a song with no key is exactly
    /// when one gets set by hand.
    func nudgeKey(by semitones: Int) {
        if let current = publishedAnalysis?.key, let coded = MIDIBridge.encode(key: current) {
            manualKey = MIDIBridge.decode(root: coded.root + semitones, minor: coded.minor)
        } else {
            manualKey = MIDIBridge.decode(root: 0, minor: false)
        }
    }

    /// By whole BPM, within the same bounds as typing one in.
    func nudgeTempo(by delta: Double) {
        guard let current = publishedAnalysis?.tempo else {
            manualTempo = 120
            return
        }
        manualTempo = min(400, max(20, (current + delta).rounded()))
    }

    /// Back to what the lookup found.
    func clearNudges() {
        manualKey = nil
        manualTempo = nil
    }

    /// One-tap sync: pressed as a line starts being sung, it shifts the whole
    /// song's lyrics so the nearest line starts now — for lyrics that are
    /// right but consistently early or late. The shift is the song's sync trim.
    func syncToLineNow() {
        guard lyricsState == .synced else {
            status = "No timed lyrics to sync."
            return
        }
        guard let (nearest, shift) = Self.syncShift(lines: lines, at: lyricPosition) else {
            status = "No line starts near here — nudge with [ and ] instead."
            return
        }
        offsetMilliseconds += shift
        let words = nearest.text.count > 40 ? String(nearest.text.prefix(39)) + "…" : nearest.text
        status = String(format: "Synced to “%@” (%+.1f s).", words, shift / 1000)
        Diagnostics.log(String(format: "sync: one-tap on a line, %+.0f ms", shift))
    }

    /// The line a one-tap sync means and the shift, in milliseconds, that
    /// starts it `now`. Nil past five seconds, which is more likely a
    /// mis-press than lyrics that far out.
    nonisolated static func syncShift(lines: [LyricLine], at now: Double) -> (LyricLine, Double)? {
        guard let nearest = lines.filter({ !$0.isBlank })
                .min(by: { abs($0.time - now) < abs($1.time - now) }),
              abs(nearest.time - now) <= 5 else { return nil }
        return (nearest, (nearest.time - now) * 1000)
    }

    // MARK: - Tap-to-time

    /// The song's lines as text, for the timing sheet to start from.
    var linesForTiming: String {
        switch lyricsState {
        case .synced:
            return lines.filter { !$0.isBlank }.map(\.text).joined(separator: "\n")
        case .plain(let text):
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        default:
            return ""
        }
    }

    /// Saves tapped timing for this song and shows it at once. The sync trim
    /// goes back to zero: tapped times are absolute.
    func saveTiming(_ entries: [(time: Double, text: String)], thenShare: Bool = false) {
        guard let track, !entries.isEmpty else { return }
        let lrc = Self.lrc(from: entries)
        Task {
            let parsed = await LyricsProvider.shared.saveUserTiming(lrc, trackID: track.trackID)
            guard self.track?.uri == track.uri, !parsed.isEmpty else { return }
            lyricsTimedByYou = true
            offsetMilliseconds = 0
            lines = parsed
            lyricsState = .synced
            refreshBeatOffset()
            Diagnostics.log("lyrics: saved your timing, \(parsed.count) lines")
            if thenShare { shareTiming() }
        }
    }

    /// Publishes this song's tapped timing on LRCLIB. Public, so only ever on
    /// an explicit request.
    func shareTiming() {
        guard let track, !sharingTiming else { return }
        sharingTiming = true
        status = "Sharing your timing on LRCLIB…"
        Task {
            defer { sharingTiming = false }
            guard let lrc = await LyricsProvider.shared.userTimingText(trackID: track.trackID) else {
                status = LRCLIBShare.ShareError.nothingToShare.localizedDescription
                return
            }
            do {
                try await LRCLIBShare.publish(trackName: track.name, artistName: track.artist,
                                              albumName: track.album, duration: track.duration, synced: lrc)
                status = "Shared “\(track.name)” on LRCLIB — thank you. It can take a little while to appear."
                Diagnostics.log("lyrics: shared your timing on LRCLIB")
            } catch {
                status = error.localizedDescription
                Diagnostics.log("ERROR lyrics share: \(error.localizedDescription)")
            }
        }
    }

    /// Back to whatever LRCLIB has.
    func discardTiming() {
        guard let track else { return }
        Task {
            await LyricsProvider.shared.removeUserTiming(trackID: track.trackID)
            guard self.track?.uri == track.uri else { return }
            lyricsTimedByYou = false
            loadLyrics(for: track)
            Diagnostics.log("lyrics: discarded your timing")
        }
    }

    /// Tapped times as LRC. `String(format:)` with no locale writes the full
    /// stop LRC needs, whatever the Mac's region.
    static func lrc(from entries: [(time: Double, text: String)]) -> String {
        "[by:Studio One tap timing]\n" + entries
            .sorted { $0.time < $1.time }
            .map { entry in
                let total = max(0, entry.time)
                let minutes = Int(total / 60)
                return String(format: "[%02d:%05.2f]", minutes, total - Double(minutes) * 60) + entry.text
            }
            .joined(separator: "\n")
    }

    // MARK: - Per-song settings

    /// The corrections a song keeps between plays. The keys predate the app's
    /// name and stay, so nothing saved is lost.
    private enum Saved {
        static let offset = PerSongSetting<Double>("trackOffsets", neutral: 0)
        static let tempoMultiplier = PerSongSetting<Double>("trackTempoMultipliers", neutral: 1)
        static let key = PerSongSetting<String>("trackManualKeys")
        static let tempo = PerSongSetting<Double>("trackManualTempos")
    }
}
