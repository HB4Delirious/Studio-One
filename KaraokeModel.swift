import Foundation
import AppKit
import Combine
import QuartzCore

enum LyricsState: Equatable {
    case idle
    case loading
    case synced
    case plain(String)
    case instrumental
    case missing
}

@MainActor
final class KaraokeModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var playerState: SpotifyPlayerState = .stopped
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var lyricsState: LyricsState = .idle
    @Published private(set) var analysis: TrackAnalysis?

    /// Where the beat grid sits, estimated once per track rather than per frame.
    @Published private(set) var beatOffset: Double = 0

    /// Colours lifted from the current cover art. Empty falls back to Theme.
    @Published private(set) var palette: [PaletteColor] = []

    /// Cover art for players that supply image data instead of a URL — Apple
    /// Music. Nil on Spotify, where `track.artworkURL` is used directly.
    @Published private(set) var localArtwork: NSImage?

    /// Halves or doubles the reported tempo. Sources sometimes read a track at
    /// half time — the only tempo error large enough to hear — and this is the
    /// correction. Saved per track, like the sync trim.
    @Published var tempoMultiplier: Double = 1 {
        didSet {
            guard !restoringTrack else { return }
            persistTempoMultiplier()
            MIDIBridge.shared.publish(publishedAnalysis)
            refreshBeatOffset()
        }
    }

    /// Key and tempo typed in by hand, for tracks no source has data for.
    @Published var manualKey: String? {
        didSet { guard !restoringTrack else { return }; persistManual(); republish() }
    }
    @Published var manualTempo: Double? {
        didSet { guard !restoringTrack else { return }; persistManual(); republish() }
    }

    /// Set while a track's saved values are put back one by one. Each of them
    /// publishes on its own when changed by hand; during a restore that sent
    /// MIDI with a mixture of the old song's values and the new one's — the
    /// previous song's hand-set key, swept out to every tuner, and left there
    /// if the new song had no key of its own. The restore publishes once, when
    /// the analysis lands.
    private var restoringTrack = false

    var hasManualValues: Bool { manualKey != nil || manualTempo != nil }

    /// Analysis as it should be shown and transmitted. Hand-entered values win
    /// outright; the ×2/÷2 correction only applies to what a source reported.
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

    /// No source had key or tempo, so put the track on the clipboard — the next
    /// step is searching for it by hand, and this saves retyping an artist like
    /// "Zero 9:36". Skipped when values were entered manually, since those
    /// already answer the question.
    private func copyTitleIfUnknown(_ track: SpotifyTrack) {
        let enabled = UserDefaults.standard.object(forKey: Self.copyOnMissKey) as? Bool ?? true
        guard enabled, publishedAnalysis == nil else { return }

        let text = "\(track.name) - \(track.artist)"
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)

        status = "No key or tempo found — “\(text)” copied to the clipboard."
    }

    /// Recomputed whenever either input lands — the lyrics and the tempo arrive
    /// from different requests and either can be first.
    private func refreshBeatOffset() {
        guard let tempo = publishedAnalysis?.tempo, !lines.isEmpty else {
            beatOffset = 0
            return
        }
        beatOffset = LRCParser.beatOffset(lines: lines, bpm: tempo)
        Diagnostics.log("  beat grid: \(String(format: "%.0f", tempo)) bpm, offset \(Int(beatOffset * 1000)) ms")
    }

    private func republish() {
        MIDIBridge.shared.publish(publishedAnalysis)
    }

    /// Output-device latency, measured and applied without user involvement.
    @Published private(set) var automaticLatencyMilliseconds: Double = 0
    @Published private(set) var connection: ConnectionState = .checking
    @Published var status: String?

    /// Manual sync trim, in milliseconds. Positive = lyrics run ahead of the music.
    @Published var offsetMilliseconds: Double = 0 {
        didSet {
            // Every nudge lands here — keys, menu, remote, a Stream Deck dial —
            // and a dial spun hard went anywhere. Ten seconds either way is far
            // more than any real misalignment. (Assigning inside didSet does
            // not call it again.)
            let clamped = min(Self.maxOffset, max(-Self.maxOffset, offsetMilliseconds))
            if clamped != offsetMilliseconds { offsetMilliseconds = clamped }
            persistOffset()
        }
    }
    static let maxOffset: Double = 10_000

    @Published var searchQuery: String = ""
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var isSearching = false

    enum ConnectionState: Equatable {
        case checking
        case ready
        case playerNotRunning
        case permissionDenied
        case failed(String)
    }

    // MARK: Internals

    let clock = PlaybackClock()

    private var controller: MusicPlayer?

    /// Which player is driving. Changing it tears the old one down and starts
    /// the other, so the switch takes effect without relaunching.
    @Published var musicSource: MusicSource = {
        let stored = UserDefaults.standard.string(forKey: MusicSource.defaultsKey)
        return stored.flatMap(MusicSource.init(rawValue:)) ?? .spotify
    }()
    private var pollTimer: Timer?
    private var playbackObserver: NSObjectProtocol?
    private var lyricsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastTrackURI: String?

    private let pollInterval: TimeInterval = 0.5
    private let offsetDefaultsKey = "trackOffsets"
    private let tempoDefaultsKey = "trackTempoMultipliers"
    private let manualKeyDefaultsKey = "trackManualKeys"
    private let manualTempoDefaultsKey = "trackManualTempos"
    static let copyOnMissKey = "copyTitleWhenUnknown"

    var isPlaying: Bool { playerState == .playing }

    /// Playback position, automatically compensated for output latency, with the
    /// user's manual trim folded in on top.
    ///
    /// Spotify reports where the playhead is, not what has reached your ears.
    /// Subtracting the measured device latency is what removes the need to dial
    /// the sync slider in by hand every time you put headphones on.
    /// Raw playback position. `lyricPosition` shifts this by the sync offset
    /// and the measured output latency, which is right for the lyrics and wrong
    /// for a progress bar.
    var playbackPosition: Double { clock.position }

    var lyricPosition: Double {
        clock.position + (offsetMilliseconds - automaticLatencyMilliseconds) / 1000
    }

    // MARK: Lifecycle

    func start() {
        // Both windows call this on appear, and a window can reappear. Without
        // this guard each call would add another observer and leave the previous
        // timer scheduled on the run loop, polling forever.
        guard pollTimer == nil else { return }

        Diagnostics.startSession()
        ControlServer.shared.start(model: self)
        // Off the main thread: it reads and compares one small file.
        Task.detached(priority: .utility) { LogicBackup.backUpIfChanged() }

        do {
            controller = try makeController()
            Diagnostics.log("\(musicSource.displayName) controller ready")
        } catch {
            Diagnostics.log("ERROR controller init failed: \(error.localizedDescription)")
            connection = .failed(error.localizedDescription)
            return
        }

        // Publishes the virtual MIDI source Logic can learn from.
        MIDIBridge.shared.start()

        // Off the main thread and detached, for the same reason the diagnostics
        // header doesn't read the keychain: a credential read can raise an
        // authorisation prompt, and blocking the launch path behind one looks
        // exactly like a freeze.
        Task.detached(priority: .utility) { await SpotifyAPI.shared.warm() }

        // Triggers the one-time macOS consent dialog on first launch.
        //
        // Deliberately off the main thread: with prompting enabled this blocks
        // until the user answers the dialog. Called on the main thread it stalls
        // the app before it draws — which looks exactly like a freeze on any Mac
        // that hasn't granted automation yet, and survives a force quit because
        // the next launch blocks in the same place.
        let bundleID = musicSource.bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SpotifyController.checkAutomationPermission(for: bundleID, prompt: true)
        }

        // Spotify broadcasts on every play, pause, seek and track change.
        // We use it purely as a "poll right now" signal rather than trusting its payload.
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
        // .common keeps polling alive while the user drags the offset slider.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let playbackObserver {
            DistributedNotificationCenter.default().removeObserver(playbackObserver)
            self.playbackObserver = nil
        }
        lyricsTask?.cancel()
        analysisTask?.cancel()
        paletteTask?.cancel()
        searchTask?.cancel()
    }

    // MARK: Polling

    /// Guards against a slow Apple Event letting polls stack up.
    private var polling = false

    private func poll() {
        guard let controller, !polling else { return }
        polling = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.polling = false }

            do {
                let snapshot = try await controller.snapshot()
                let latency = await AudioLatency.measuredMilliseconds()
                self.apply(snapshot: snapshot, latency: latency)
            } catch {
                self.handle(error)
            }
        }
    }

    private func apply(snapshot: SpotifySnapshot, latency: Double) {
        if connection != .ready {
            Diagnostics.log("connection: ready")
            // An error from while the player was away ("isn't running") is
            // no longer true, and left up it reads as a current problem.
            status = nil
            connection = .ready
        }

        // Each of these is assigned only when it differs. A published value
        // announces a change on every assignment, equal or not, and every
        // view watching the model rebuilds — both windows, twice a second,
        // with nothing playing: 12–15% CPU on an idle app.
        //
        // Assign `track` first: handleTrackChange writes the saved offset, and
        // persistOffset keys off the *current* track.
        let changed = snapshot.track?.uri != lastTrackURI
        lastTrackURI = snapshot.track?.uri
        if track != snapshot.track { track = snapshot.track }
        if changed { handleTrackChange(snapshot.track) }

        if playerState != snapshot.state { playerState = snapshot.state }

        if abs(latency - automaticLatencyMilliseconds) > 1 {
            Diagnostics.log("output latency: \(Int(latency)) ms (applied automatically)")
            automaticLatencyMilliseconds = latency
        }

        // A reading taken before a seek landed still says where the song
        // *was*. Taken as truth it snapped the lyrics back, then forward again
        // on the next poll — a half-second stutter after every seek.
        let playing = snapshot.state == .playing
        if seeksInFlight > 0 || snapshot.sampledAt < positionTrustedFrom {
            if playing != clock.isPlaying { clock.reset(to: clock.position, playing: playing) }
        } else {
            let before = clock.position
            clock.ingest(sample: snapshot.position, sampledAt: snapshot.sampledAt, playing: playing)
            recordIfSung()
            // Paused, nothing redraws on its own any more; a position moved in
            // the player itself has to say so.
            if !playing, abs(clock.position - before) > 0.05 { clockMoved() }
        }
    }

    /// Bumped when the position moves while paused. Playing, the lyric view
    /// redraws every frame anyway; paused it only redraws on a change, and
    /// the clock is not itself published.
    @Published private(set) var pausedMoves = 0

    private func clockMoved() {
        if !clock.isPlaying { pausedMoves &+= 1 }
    }

    /// Seeks sent but not yet answered, and when the last one was.
    private var seeksInFlight = 0
    private var positionTrustedFrom: CFTimeInterval = 0

    private func handle(_ error: Error) {
        let next: ConnectionState
        if let error = error as? SpotifyControllerError {
            switch error {
            case .notRunning:    next = .playerNotRunning
            case .notAuthorized: next = .permissionDenied
            default:             next = .failed(error.localizedDescription)
            }
        } else {
            next = .failed(error.localizedDescription)
        }

        // Only on a change, for the same reason as in `apply`: with the player
        // closed this ran twice a second and rebuilt both windows each time.
        if connection != next {
            Diagnostics.log("connection: \(next) — \(error.localizedDescription)")
            connection = next
        }
    }

    private func handleTrackChange(_ newTrack: SpotifyTrack?) {
        lyricsTask?.cancel()
        analysisTask?.cancel()
        paletteTask?.cancel()
        status = nil
        lines = []
        analysis = nil
        palette = []
        clock.reset(to: 0, playing: false)

        guard let newTrack else {
            Diagnostics.log("track: none")
            lyricsState = .idle
            restoringTrack = true
            offsetMilliseconds = 0
            tempoMultiplier = 1
            manualKey = nil
            manualTempo = nil
            restoringTrack = false
            MIDIBridge.shared.stopClock()
            return
        }

        Diagnostics.log("track: \(newTrack.name) — \(newTrack.artist) [\(newTrack.trackID)] \(Int(newTrack.duration))s")
        Diagnostics.log("  sync: trim \(Int(storedOffset(for: newTrack.trackID))) ms + auto -\(Int(automaticLatencyMilliseconds)) ms")

        paletteTask = Task { [weak self] in
            guard let self else { return }

            // A URL is the fast path. Without one, ask the player for the image
            // itself — that is the only route on Apple Music.
            if newTrack.artworkURL == nil, let browser = self.browser {
                let image = await browser.currentArtwork().flatMap(NSImage.init(data:))
                guard !Task.isCancelled, self.track?.uri == newTrack.uri else { return }
                self.localArtwork = image
                self.palette = image.map { PaletteProvider.shared.palette(for: $0) } ?? []
                return
            }

            self.localArtwork = nil
            let colours = await PaletteProvider.shared.palette(for: newTrack)
            guard !Task.isCancelled, self.track?.uri == newTrack.uri else { return }
            self.palette = colours
        }

        analysisTask = Task { [weak self] in
            let result = await AnalysisProvider.shared.analysis(for: newTrack)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.track?.uri == newTrack.uri else { return }
                self.analysis = result
                self.refreshBeatOffset()
                if let result {
                    Diagnostics.log("analysis: key=\(result.key ?? "-") tempo=\(result.tempo.map { String(format: "%.2f", $0) } ?? "-")\(result.halfTimeSuspect ? " HALF-TIME SUSPECT" : "")")
                } else {
                    Diagnostics.log("analysis: nothing from any source")
                }
                MIDIBridge.shared.publish(self.publishedAnalysis)
                self.copyTitleIfUnknown(newTrack)
            }
        }

        restoringTrack = true
        offsetMilliseconds = storedOffset(for: newTrack.trackID)
        tempoMultiplier = storedTempoMultiplier(for: newTrack.trackID)
        let manuals = storedManual(for: newTrack.trackID)
        manualKey = manuals.key
        manualTempo = manuals.tempo
        restoringTrack = false

        refreshNextUp()
        recordedThisPlay = false

        // This song's plug-in settings, if any are set up. They don't wait
        // for the analysis: they depend only on which song it is.
        MIDIBridge.shared.sendSongControls(SongControl.messages(trackID: newTrack.trackID),
                                           sweep: true, label: "Song settings")

        loadLyrics(for: newTrack)
    }

    private func loadLyrics(for newTrack: SpotifyTrack) {
        lyricsTask?.cancel()
        lines = []
        lyricsState = .loading
        lyricsTimedByYou = false
        lyricsTask = Task { [weak self] in
            let result = await LyricsProvider.shared.lyrics(for: newTrack)
            let mine = await LyricsProvider.shared.hasUserTiming(trackID: newTrack.trackID)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.track?.uri == newTrack.uri else { return }
                self.lyricsTimedByYou = mine
                self.apply(result)
            }
        }
    }

    // MARK: History

    /// Whether this play of the current song is in the history yet.
    private var recordedThisPlay = false

    /// A song goes into the night's history once it has played for thirty
    /// seconds — enough to leave skips out.
    private func recordIfSung() {
        guard !recordedThisPlay, isPlaying, let track, clock.position >= 30 else { return }
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

    // MARK: Up next

    /// The song after this one in the player's queue, for the lyrics screen.
    @Published private(set) var nextUp: LibraryTrack?

    /// Re-read on every song change, and when a guest's request changes the
    /// queue. Only sources with a queue to read have one.
    func refreshNextUp() {
        guard let browser, browser.canBrowseLibrary, track != nil else {
            if nextUp != nil { nextUp = nil }
            return
        }
        let playing = track?.uri
        Task {
            let queue = (try? await browser.upNext(limit: 2)) ?? nil
            guard self.track?.uri == playing else { return }
            let next = queue?.tracks.dropFirst().first
            if nextUp != next { nextUp = next }
        }
    }

    // MARK: Tap-to-time

    /// Whether the lyrics showing are ones you timed yourself.
    @Published private(set) var lyricsTimedByYou = false

    /// While the timing sheet is taking taps. The Playback menu gives up its
    /// bare Space shortcut meanwhile, or every tap would also pause the song.
    @Published var isTimingLyrics = false

    /// The song's lines as text, for the timing sheet to start from: the
    /// timed or untimed lyrics already found, or nothing.
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

    /// What is being heard right now, in song time: the playhead less the
    /// output's delay. A tap is made on what the ear hears.
    var heardPosition: Double {
        max(0, clock.position - automaticLatencyMilliseconds / 1000)
    }

    /// Saves tapped timing for the current track and shows it at once. The
    /// sync trim goes back to zero: these times are absolute, and a trim set
    /// for the old lyrics would push the new ones out.
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

    /// While a share to LRCLIB is under way.
    @Published private(set) var sharingTiming = false

    /// Publishes your timing for the current song on LRCLIB. Only ever run
    /// on an explicit request: it is public.
    func shareTiming() {
        guard let track, !sharingTiming else { return }
        sharingTiming = true
        status = "Sharing your timing on LRCLIB…"
        Task {
            defer { self.sharingTiming = false }
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

    /// Tapped times as an LRC file. `String(format:)` without a locale always
    /// writes a full stop, which is what LRC needs.
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

    private func apply(_ result: LyricsResult) {
        switch result {
        case .synced(let lines):
            Diagnostics.log("lyrics: synced, \(lines.count) lines")
        case .plain:
            Diagnostics.log("lyrics: plain only (untimed)")
        case .instrumental:
            Diagnostics.log("lyrics: instrumental")
        case .notFound:
            Diagnostics.log("lyrics: not found")
        }

        switch result {
        case .synced(let parsed):
            lines = parsed
            lyricsState = .synced
            refreshBeatOffset()
        case .plain(let text):
            lines = []
            lyricsState = .plain(text)
        case .instrumental:
            lines = []
            lyricsState = .instrumental
        case .notFound:
            lines = []
            lyricsState = .missing
        }
    }

    /// Fetches the lyrics again, and only the lyrics. This used to rerun the
    /// whole track change: the lyric clock jumped to the start until the next
    /// poll, and the key was looked up and swept out to Logic all over again.
    func reloadLyrics() {
        guard let track else { return }
        Task {
            await LyricsProvider.shared.invalidate(trackID: track.trackID)
            guard self.track?.uri == track.uri else { return }
            loadLyrics(for: track)
        }
    }

    // MARK: Transport

    func togglePlayback() { perform { try await $0.playPause() } }
    func nextTrack() { perform { try await $0.next() } }
    func previousTrack() { perform { try await $0.previous() } }
    /// Correct the key by semitones from the remote.
    ///
    /// This writes `manualKey`, the same override the control bar sets, so it
    /// persists per track and republishes to Logic. It corrects what the app
    /// *believes* the key is — it cannot transpose the audio, which comes from
    /// Apple Music as a finished mix.
    func nudgeKey(by semitones: Int) {
        if let current = publishedAnalysis?.key,
           let coded = MIDIBridge.encode(key: current) {
            manualKey = MIDIBridge.decode(root: coded.root + semitones, minor: coded.minor)
        } else {
            // Nothing was detected. Start at C rather than doing nothing —
            // a track with no analysis is exactly when a manual value is
            // wanted, and a dead button reads as broken.
            manualKey = MIDIBridge.decode(root: 0, minor: false)
        }
    }

    /// Correct the tempo by whole BPM, with the same caveat.
    func nudgeTempo(by delta: Double) {
        guard let current = publishedAnalysis?.tempo else {
            manualTempo = 120          // same reasoning as the key
            return
        }
        // Same bounds as typing one in, so a nudge never jumps a tempo.
        manualTempo = min(400, max(20, (current + delta).rounded()))
    }

    /// Clear both corrections and fall back to what the lookup found.
    func clearNudges() {
        manualKey = nil
        manualTempo = nil
    }

    func revealPlayer() { controller?.activate() }

    /// The library browser for the current source, when it has one. Only Apple
    /// Music does — see the note on `MusicBrowser`.
    var browser: MusicBrowser? { controller as? MusicBrowser }
    var canSearch: Bool { controller?.supportsPlayingByID ?? false }

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

    /// One-tap sync: press as a line starts being sung, and the whole song's
    /// lyrics shift so that line starts now. For lyrics that are right but
    /// consistently early or late — the commonest fault, and the one the
    /// [ and ] nudges fix fifty milliseconds at a time.
    ///
    /// The line taken is the one whose start is nearest to where the lyrics
    /// think the song is. Lines are usually seconds apart and the error a
    /// second or two, so that is the line being heard. The shift lands in the
    /// per-song sync trim, so it is saved like any other.
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

    /// The line a one-tap sync means, and the shift in milliseconds that
    /// makes it start at `now`. Nil when no line starts within five seconds: further than that is more likely a mis-press than lyrics that far out.
    nonisolated static func syncShift(lines: [LyricLine], at now: Double) -> (LyricLine, Double)? {
        guard let nearest = lines.filter({ !$0.isBlank })
                .min(by: { abs($0.time - now) < abs($1.time - now) }),
              abs(nearest.time - now) <= 5 else { return nil }
        return (nearest, (nearest.time - now) * 1000)
    }

    /// Jump to the start of a lyric line — handy for practising one verse.
    func jump(to line: LyricLine) {
        seek(to: max(0, line.time - offsetMilliseconds / 1000))
    }

    func play(_ result: SearchResult) {
        perform { try await $0.play(uri: result.uri) }
        searchResults = []
        searchQuery = ""
    }

    /// Rebuilds the controller for the selected source. Safe to call while
    /// running — polling continues against whichever player is now active.
    func changeSource(to newSource: MusicSource) {
        guard newSource != musicSource else { return }
        Diagnostics.log("source: switching to \(newSource.displayName)")

        musicSource = newSource
        UserDefaults.standard.set(newSource.rawValue, forKey: MusicSource.defaultsKey)

        // The request line works through the Apple Music it started with. Left
        // running after a switch, guests went on filling a playlist nobody was
        // playing, behind a QR code that still looked live.
        if RequestServer.shared.running, newSource != .appleMusic {
            RequestServer.shared.stop(because: "Stopped: requests need Apple Music as the source.")
        }

        lastTrackURI = nil
        track = nil
        handleTrackChange(nil)
        connection = .checking

        do {
            controller = try makeController()
            Diagnostics.log("\(newSource.displayName) controller ready")
        } catch {
            Diagnostics.log("ERROR controller init failed: \(error.localizedDescription)")
            controller = nil
            connection = .failed(error.localizedDescription)
            return
        }

        // Consent is per-application, so a first switch prompts once. Off the
        // main thread — that call blocks until the dialog is answered.
        let bundleID = newSource.bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            _ = SpotifyController.checkAutomationPermission(for: bundleID, prompt: true)
        }

        poll()
    }

    private func makeController() throws -> MusicPlayer {
        switch musicSource {
        case .spotify:    return try SpotifyController()
        case .appleMusic: return try AppleMusicController()
        }
    }

    private func perform(_ action: @escaping (MusicPlayer) async throws -> Void) {
        guard let controller else { return }
        Task {
            do {
                try await action(controller)
                status = nil
                // Show the result now rather than on the next poll.
                poll()
            } catch {
                Diagnostics.log("ERROR transport: \(error.localizedDescription)")
                status = error.localizedDescription
            }
        }
    }

    /// For the library and request line: same error handling as the transport.
    /// These failed silently before, which reads as "nothing happens".
    func performOnBrowser(_ action: @escaping (MusicBrowser) async throws -> Void) {
        guard let browser else { return }
        Task {
            do {
                try await action(browser)
                status = nil
                poll()
            } catch {
                Diagnostics.log("ERROR playback: \(error.localizedDescription)")
                status = error.localizedDescription
            }
        }
    }

    // MARK: Search

    func runSearch() {
        searchTask?.cancel()
        let query = searchQuery

        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            searchResults = []
            return
        }

        searchTask = Task { [weak self] in
            // Debounce so we don't fire a request per keystroke.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { self?.isSearching = true }
            do {
                let results = try await SpotifyAPI.shared.search(query)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.searchResults = results
                    self?.isSearching = false
                    self?.status = results.isEmpty ? "No tracks matched “\(query)”." : nil
                }
            } catch {
                await MainActor.run {
                    Diagnostics.log("ERROR search: \(error.localizedDescription)")
                    self?.isSearching = false
                    self?.status = error.localizedDescription
                }
            }
        }
    }

    // MARK: Offset persistence

    private func storedOffset(for trackID: String) -> Double {
        let map = UserDefaults.standard.dictionary(forKey: offsetDefaultsKey) as? [String: Double] ?? [:]
        return map[trackID] ?? 0
    }

    private func storedTempoMultiplier(for trackID: String) -> Double {
        let map = UserDefaults.standard.dictionary(forKey: tempoDefaultsKey) as? [String: Double] ?? [:]
        return map[trackID] ?? 1
    }

    private func persistTempoMultiplier() {
        guard let trackID = track?.trackID else { return }
        var map = UserDefaults.standard.dictionary(forKey: tempoDefaultsKey) as? [String: Double] ?? [:]
        if tempoMultiplier == 1 {
            map.removeValue(forKey: trackID)
        } else {
            map[trackID] = tempoMultiplier
        }
        UserDefaults.standard.set(map, forKey: tempoDefaultsKey)
    }

    private func storedManual(for trackID: String) -> (key: String?, tempo: Double?) {
        let keys = UserDefaults.standard.dictionary(forKey: manualKeyDefaultsKey) as? [String: String] ?? [:]
        let tempos = UserDefaults.standard.dictionary(forKey: manualTempoDefaultsKey) as? [String: Double] ?? [:]
        return (keys[trackID], tempos[trackID])
    }

    private func persistManual() {
        guard let trackID = track?.trackID else { return }

        var keys = UserDefaults.standard.dictionary(forKey: manualKeyDefaultsKey) as? [String: String] ?? [:]
        keys[trackID] = manualKey
        UserDefaults.standard.set(keys, forKey: manualKeyDefaultsKey)

        var tempos = UserDefaults.standard.dictionary(forKey: manualTempoDefaultsKey) as? [String: Double] ?? [:]
        tempos[trackID] = manualTempo
        UserDefaults.standard.set(tempos, forKey: manualTempoDefaultsKey)
    }

    private func persistOffset() {
        guard let trackID = track?.trackID else { return }
        var map = UserDefaults.standard.dictionary(forKey: offsetDefaultsKey) as? [String: Double] ?? [:]
        if offsetMilliseconds == 0 {
            map.removeValue(forKey: trackID)
        } else {
            map[trackID] = offsetMilliseconds
        }
        UserDefaults.standard.set(map, forKey: offsetDefaultsKey)
    }

    // MARK: Lyric lookup

    /// Index of the line that should be lit up right now, or nil before the first line.
    func activeIndex(at position: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var found: Int? = nil
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
}
