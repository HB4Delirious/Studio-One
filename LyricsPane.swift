import AppKit
import SwiftUI

/// Everything the lyrics display draws: the backdrop, and whichever stage state
/// applies — connecting, no lyrics, instrumental, or the running sweep.
///
/// Shared by the lyrics window and the Controls window's preview, so the
/// preview is always the real thing.
struct LyricsPane: View {
    @EnvironmentObject private var model: KaraokeModel
    /// Redrawn when the venue's theme changes: its colours are read in drawing.
    @ObservedObject private var venue = VenueThemes.shared
    @ObservedObject private var games = PartyGames.shared
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum
    @AppStorage(LyricsStyle.defaultsKey) private var style: LyricsStyle = .highlight

    let fontSize: CGFloat

    /// Redraw ceiling: the display's rate for the window, lower for the preview.
    var maximumFPS: Double = .infinity

    var body: some View {
        stage
            .overlay { SingerBanner() }
            // Between songs, the break screen: who's next, the code to request.
            .overlay {
                if let pause = model.intermission {
                    IntermissionView(pause: pause)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: model.intermission != nil)
            // Name that tune: the song's title and lyrics hidden from the room.
            .overlay {
                if let tune = games.tune, tune.uri == model.track?.uri, model.intermission == nil {
                    NameThatTuneView(tune: tune)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: games.tune)
            .overlay(alignment: .bottomTrailing) { RecordingBadge() }
            .background { LyricsBackdrop().ignoresSafeArea() }
    }

    /// What the room sees. Nothing here is meant for the host: with no song
    /// it's the standby screen; with a song but nothing to follow, its title.
    /// What's wrong, and what to press, is in the Controls window.
    @ViewBuilder
    private var stage: some View {
        // House music with nothing queued: the room sees the standby screen.
        if model.connection != .ready || (model.fillerPlaying && model.intermission == nil) {
            StandbyView()
        } else {
            lyricStage
        }
    }

    @ViewBuilder
    private var lyricStage: some View {
        switch model.lyricsState {
        case .idle:
            StandbyView()

        case .loading, .missing:
            SongCard(track: model.track)

        case .instrumental:
            SongCard(track: model.track, note: "Instrumental")

        case .plain(let text):
            ScrollView {
                Text(text)
                    .font(Theme.lyric(20, active: false))
                    .foregroundStyle(Theme.upcoming)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(44)
            }

        case .synced where style == .page:
            LyricsPage(lines: model.lines, fontSize: fontSize)

        case .synced:
            // Redrawn off the display's refresh. Without the sweep, 30 fps is
            // plenty: line changes animate by themselves.
            TimelineView(.animation(minimumInterval: FrameRate.interval(
                                        for: targetFPS,
                                        ceiling: style == .highlight ? maximumFPS : min(30, maximumFPS)),
                                    paused: !model.isPlaying)) { _ in
                let position = model.lyricPosition
                let index = model.activeIndex(at: position)

                ZStack(alignment: .top) {
                    LyricsStage(
                        lines: model.lines,
                        position: position,
                        activeIndex: index,
                        fontSize: fontSize,
                        tempo: model.publishedAnalysis?.tempo,
                        beatOffset: model.beatOffset,
                        highlight: style == .highlight,
                        mask: { [uri = model.track?.uri] line in
                            PartyGames.shared.maskFrom(line, uri: uri, at: position)
                        },
                        partLevel: { MicMeters.level(for: $0) },
                        onJump: { model.jump(to: $0) })

                    if let gap = upcomingGap(at: position, activeIndex: index) {
                        CueCountdown(secondsRemaining: gap)
                            .padding(.top, 22)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    /// Seconds until the next line, but only once we're inside the final 4 seconds
    /// of a gap long enough to feel like dead air.
    private func upcomingGap(at position: Double, activeIndex: Int?) -> Double? {
        let nextIndex = (activeIndex.map { $0 + 1 }) ?? 0
        guard nextIndex < model.lines.count else { return nil }

        let next = model.lines[nextIndex]
        let gapStart = activeIndex.map { model.lines[$0].end } ?? 0
        guard next.time - gapStart >= 4 else { return nil }

        let remaining = next.time - position
        return (remaining > 0 && remaining <= 4) ? remaining : nil
    }
}

/// Every line of the song at once, for `LyricsStyle.page`. Nothing scrolls or
/// lights up by itself.
struct LyricsPage: View {
    let lines: [LyricLine]
    let fontSize: CGFloat

    var body: some View {
        ScrollView {
            LyricsPageText(lines: lines, fontSize: fontSize)
        }
    }
}

/// The page's text, apart from its scroll view.
struct LyricsPageText: View {
    let lines: [LyricLine]
    let fontSize: CGFloat

    var body: some View {
        // A plain stack: a song is a hundred lines at most, all of it text.
        VStack(spacing: fontSize * 0.34) {
            ForEach(lines) { line in
                if line.isBlank {
                    // An instrumental gap reads as a verse break.
                    Color.clear.frame(height: fontSize * 0.4)
                } else {
                    Text(line.text)
                        .font(.system(size: fontSize * 0.62, weight: .bold, design: Theme.stageDesign))
                        // A duet reads by colour: each part tinted as it's sung.
                        .foregroundStyle(line.part == nil ? Color.white.opacity(0.92)
                                                          : Theme.part(line.part).opacity(0.95))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 48)
    }
}

/// Who's singing, and who's next, on the lyrics screen. "Now singing" for the
/// first few seconds of a song a guest requested; "Up next" over the last
/// thirty seconds, with the guest's name when the next song was a request.
/// "● REC" in a corner of the room's screen while a performance is being
/// recorded, so nobody's recorded unawares.
struct RecordingBadge: View {
    @ObservedObject private var performances = Performances.shared

    var body: some View {
        if performances.current != nil {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("REC")
                    .font(.system(size: 12, weight: .heavy, design: Theme.stageDesign))
                    .tracking(1)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .padding(24)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

struct SingerBanner: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var requests = RequestServer.shared
    @AppStorage(Self.enabledKey) private var enabled = true

    static let enabledKey = "showSingerBanner"

    var body: some View {
        if enabled, model.connection == .ready, model.intermission == nil, !model.fillerPlaying,
           PartyGames.shared.tune == nil, let track = model.track {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let position = model.playbackPosition
                let remaining = track.duration - position
                VStack {
                    if position < 12, let who = requests.requester(name: track.name, artist: track.artist) {
                        chip("NOW SINGING", who)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }
                    Spacer()
                    if track.duration > 0, remaining > 0, remaining < 30, let next = model.nextUp {
                        let who = requests.requester(name: next.name, artist: next.artist)
                        chip("UP NEXT", [who, next.name].compactMap { $0 }.joined(separator: " · "))
                            .transition(.opacity)
                    }
                }
                .padding(24)
                .animation(.easeInOut(duration: 0.5), value: position < 12)
                .animation(.easeInOut(duration: 0.5), value: remaining < 30)
            }
            .allowsHitTesting(false)
        }
    }

    private func chip(_ label: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .heavy, design: Theme.stageDesign))
                .foregroundStyle(Theme.cue)
            Text(text)
                .font(.system(size: 20, weight: .bold, design: Theme.stageDesign))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// Behind the lyrics: the flat ground, and the particle field once there's a
/// song to react to.
struct LyricsBackdrop: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var venue = VenueThemes.shared

    var body: some View {
        ZStack {
            // A venue's own colour, plain; otherwise the cover's, moving.
            if let solid = VenueLook.current.background {
                solid
            } else {
                Theme.backdrop
                if model.track != nil {
                    AmbientBackground()
                }
            }
        }
    }
}

/// The lyrics display, live and small, in the corner of the controls window.
///
/// Laid out at full size and scaled down: the stage's type sizes are absolute,
/// so at thumbnail width every line would wrap differently.
struct StagePreview: View {
    static let enabledKey = "stagePreviewInControls"

    /// 16:9, the shape a lyrics window ends up on a TV.
    static let design = CGSize(width: 1024, height: 576)
    static let aspect = design.height / design.width

    /// The preview's own lyric size, for its 16:9 frame: the size buttons are
    /// for the room's screen, and at their largest the lines no longer fit a
    /// thumbnail, so they'd pile on top of each other.
    static let fontSize = CGFloat(LyricSize.standard)

    let width: CGFloat

    /// The design size the whole frame is drawn at, backdrop included, before
    /// scaling.
    var body: some View {
        LyricsPane(fontSize: Self.fontSize, maximumFPS: 30)
            .frame(width: Self.design.width, height: Self.design.height)
            // Centre-anchored: `scaleEffect` doesn't change the layout size,
            // and only the centre is shared by the drawn image and its box —
            // top-leading, the frame below clips the preview away.
            .scaleEffect(width / Self.design.width)
            .frame(width: width, height: width * Self.aspect)
            .clipped()
            // A tap on a line seeks; a click on the thumbnail shouldn't.
            .allowsHitTesting(false)
    }
}

