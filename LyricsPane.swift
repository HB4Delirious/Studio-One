import AppKit
import SwiftUI

/// Everything the lyrics display draws: the backdrop, and whichever stage state
/// applies — connecting, no lyrics, instrumental, or the running sweep.
///
/// Lifted out of `LyricsWindow` so the controls window can show the same view
/// scaled down. A second implementation of the stage would be a second thing to
/// keep in step, and the whole point of a preview is that it is not.
struct LyricsPane: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum
    @AppStorage(LyricsStyle.defaultsKey) private var style: LyricsStyle = .highlight

    let fontSize: CGFloat

    /// Redraw ceiling. The window leaves this alone and follows the display;
    /// the preview lowers it, because nobody is reading a 300-point thumbnail
    /// closely enough to notice.
    var maximumFPS: Double = .infinity

    var body: some View {
        stage
            .overlay { SingerBanner() }
            .background { LyricsBackdrop().ignoresSafeArea() }
    }

    @ViewBuilder
    private var stage: some View {
        switch model.connection {
        case .checking:
            StageMessage(title: "Looking for \(model.musicSource.displayName)…", detail: nil)

        case .playerNotRunning:
            StageMessage(
                title: "\(model.musicSource.displayName) isn't open",
                detail: "Launch \(model.musicSource.displayName) and press play. Studio One follows whatever you're listening to.",
                action: ("Open \(model.musicSource.displayName)", {
                    guard let url = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: model.musicSource.bundleID) else { return }
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }))

        case .permissionDenied:
            StageMessage(
                title: "Studio One can't reach \(model.musicSource.displayName)",
                detail: "macOS gates app-to-app control. Turn on \(model.musicSource.displayName) under Privacy & Security › Automation, then reopen Studio One.",
                action: ("Open Automation settings", { SpotifyController.openAutomationSettings() }))

        case .failed(let message):
            StageMessage(title: "Something went wrong", detail: message)

        case .ready:
            lyricStage
        }
    }

    @ViewBuilder
    private var lyricStage: some View {
        switch model.lyricsState {
        case .idle:
            StageMessage(title: "Nothing playing",
                         detail: "Start a track in \(model.musicSource.displayName), or pick one in the Controls window.")

        case .loading:
            StageMessage(title: "Fetching lyrics…", detail: nil)

        case .missing:
            StageMessage(
                title: "No timed lyrics for this one",
                detail: "LRCLIB doesn't have a synced version yet. Look again in case the match failed, or paste the words in and time them yourself: the hand button in the Controls window.",
                action: ("Look again", { model.reloadLyrics() }))

        case .instrumental:
            StageMessage(title: "Instrumental", detail: "This track has no vocal line to follow.")

        case .plain(let text):
            ScrollView {
                Text(text)
                    .font(Theme.lyric(20, active: false))
                    .foregroundStyle(Theme.upcoming)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(44)
            }
            .overlay(alignment: .top) {
                Text("Untimed lyrics — time them with the hand button in Controls")
                    .font(Theme.label)
                    .foregroundStyle(Theme.cue)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Theme.panel, in: Capsule())
                    .padding(.top, 12)
            }

        case .synced where style == .page:
            LyricsPage(lines: model.lines, fontSize: fontSize)

        case .synced:
            // TimelineView drives redraws off the display refresh instead of
            // republishing position 30x a second through Combine. Without the
            // sweep, 30fps is plenty: line changes animate on their own, and
            // only the ghosted backing vocals fade frame by frame.
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

/// Backdrop behind the lyrics: the flat ground plus the particle field, which
/// only appears once there is a track to react to.
/// Every line of the song at once, for `LyricsStyle.page`. Still on purpose:
/// nothing scrolls or lights up by itself.
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
                        .font(.system(size: fontSize * 0.62, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
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
struct SingerBanner: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var requests = RequestServer.shared
    @AppStorage(Self.enabledKey) private var enabled = true

    static let enabledKey = "showSingerBanner"

    var body: some View {
        if enabled, model.connection == .ready, let track = model.track {
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
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.cue)
            Text(text)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

struct LyricsBackdrop: View {
    @EnvironmentObject private var model: KaraokeModel

    var body: some View {
        ZStack {
            Theme.backdrop
            if model.track != nil {
                AmbientBackground()
            }
        }
    }
}

/// The lyrics display, live and small, in the corner of the controls window.
///
/// Never laid out at thumbnail size: the stage's type sizes are absolute points,
/// so 300 points of width would wrap every line and re-centre the sweep — a
/// tidy picture of something the room will never see.
struct StagePreview: View {
    @AppStorage("lyricFontSize") private var fontSize: Double = 42

    static let enabledKey = "stagePreviewInControls"

    /// 16:9, the shape a lyrics window ends up on a TV.
    static let design = CGSize(width: 1024, height: 576)
    static let aspect = design.height / design.width

    let width: CGFloat

    /// Rendered at a fixed design size and then scaled — the whole frame,
    /// backdrop included.
    ///
    /// Drawing the backdrop separately at thumbnail size was tried, on the
    /// theory that scaling meant computing a full-size blur and discarding most
    /// of it. It saved nothing measurable, and it made the preview less honest:
    /// the particles came out at their absolute size, so proportionally much
    /// larger than the room sees. Scaling everything shows the real frame.
    var body: some View {
        LyricsPane(fontSize: CGFloat(fontSize), maximumFPS: 30)
            .frame(width: Self.design.width, height: Self.design.height)
            // Centre anchor, deliberately. `scaleEffect` is a geometry effect:
            // it changes what is drawn, never the size the view lays out at, so
            // this still occupies 1024x576 to the frame below. Centre-anchored,
            // the drawn image and its layout box share a centre and the frame
            // lands on it exactly. Anchored top-leading they do not, and the
            // whole preview is clipped away to an empty rectangle.
            .scaleEffect(width / Self.design.width)
            .frame(width: width, height: width * Self.aspect)
            .clipped()
            // A tap on a line seeks, and a stray click on a thumbnail should not
            // move the room's music. The frame around this is the click target.
            .allowsHitTesting(false)
    }
}
