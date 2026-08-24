import SwiftUI
import AppKit

/// The lyrics display, on its own so it can live full-screen on a second screen
/// or a TV while the controls stay on your main display.
struct LyricsWindow: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage("lyricFontSize") private var fontSize: Double = 42
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum
    @Environment(\.openWindow) private var openWindow
    @State private var isFullScreen = false
    // A reference box, deliberately not @State holding the window itself:
    // assigning an NSWindow to @State invalidates the view, which re-runs
    // updateNSView, which assigns again — an update loop that made the green
    // button strobe between zoom and full screen.
    @State private var host = WindowHolder()

    var body: some View {
        stage
            .background {
                ZStack {
                    Theme.backdrop
                    if model.track != nil {
                        AmbientBackground()
                    }
                }
                .ignoresSafeArea()
            }
            .frame(minWidth: 480, minHeight: 320)
            .preferredColorScheme(.dark)
            // Full screen is the performance view: nothing but lyrics.
            .toolbar(isFullScreen ? .hidden : .visible, for: .windowToolbar)
            .background(WindowReader { window in
                host.window = window
                // A Window scene doesn't advertise full-screen support, so the
                // green button offers zoom (+) instead of the full-screen arrows.
                // WindowGroup sets this for you; Window does not.
                window.collectionBehavior.insert(.fullScreenPrimary)
            })
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didEnterFullScreenNotification)) { note in
                if isThisWindow(note) { isFullScreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didExitFullScreenNotification)) { note in
                if isThisWindow(note) { isFullScreen = false }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(id: SpotifyKaraokeApp.controlsWindowID)
                    } label: {
                        Label("Controls", systemImage: "slider.horizontal.3")
                    }
                    .help("Bring back the controls window")
                }
            }
            // start() is idempotent, and both windows call it — whichever opens
            // first wins. Polling is deliberately not stopped when a window
            // closes, or shutting the lyrics window would halt the controls too.
            .onAppear { model.start() }
    }

    /// Full-screen notifications fire for every window in the app. Compare
    /// against the actual hosting window rather than its title, which SwiftUI is
    /// free to change or localise.
    private func isThisWindow(_ note: Notification) -> Bool {
        guard let window = note.object as? NSWindow, let host = host.window else { return false }
        return window === host
    }

    @ViewBuilder
    private var stage: some View {
        switch model.connection {
        case .checking:
            StageMessage(title: "Looking for Spotify…", detail: nil)

        case .spotifyNotRunning:
            StageMessage(
                title: "Spotify isn't open",
                detail: "Launch Spotify and press play. Karaoke follows whatever you're listening to.",
                action: ("Open Spotify", {
                    guard let url = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: SpotifyController.bundleID) else { return }
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }))

        case .permissionDenied:
            StageMessage(
                title: "Karaoke can't reach Spotify",
                detail: "macOS gates app-to-app control. Turn on Spotify under Privacy & Security › Automation, then reopen Karaoke.",
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
            StageMessage(title: "Nothing playing", detail: "Start a track in Spotify, or search for one below.")

        case .loading:
            StageMessage(title: "Fetching lyrics…", detail: nil)

        case .missing:
            StageMessage(
                title: "No timed lyrics for this one",
                detail: "LRCLIB doesn't have a synced version yet. Try another track, or re-check in case the match failed.",
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
                Text("Untimed lyrics — these won't follow the music")
                    .font(Theme.label)
                    .foregroundStyle(Theme.cue)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Theme.panel, in: Capsule())
                    .padding(.top, 12)
            }

        case .synced:
            // TimelineView drives redraws off the display refresh instead of
            // republishing position 30x a second through Combine.
            TimelineView(.animation(minimumInterval: FrameRate.interval(for: targetFPS),
                                    paused: !model.isPlaying)) { _ in
                let position = model.lyricPosition
                let index = model.activeIndex(at: position)

                ZStack(alignment: .top) {
                    LyricsStage(
                        lines: model.lines,
                        position: position,
                        activeIndex: index,
                        fontSize: CGFloat(fontSize),
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

/// Transport, track info, sync and settings — everything that isn't the lyrics.
struct ControlsWindow: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage("lyricFontSize") private var fontSize: Double = 42
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showManualEntry = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geo in
            // Short and wide keeps the compact strip. Given real height, the
            // artwork becomes the centrepiece and the controls pin to the bottom.
            let roomy = geo.size.height >= 320
            let artwork = roomy
                ? min(max(140, geo.size.height * 0.36), 360)
                : 38

            VStack(spacing: 0) {
                if roomy { Spacer(minLength: 0) }

                NowPlayingHeader(artworkSize: artwork, centred: roomy)

                if roomy { Spacer(minLength: 0) }

                Divider().overlay(Theme.hairline)
                ControlBar(fontSize: $fontSize, showSearch: $showSearch)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minWidth: 380, minHeight: 130)
        .background(TintedPanel(tint: model.palette.accent,
                                strength: model.palette.tintStrength))
        .animation(.easeInOut(duration: 1.2), value: model.palette)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSearch) { SearchSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: SpotifyKaraokeApp.lyricsWindowID)
                } label: {
                    Label("Lyrics", systemImage: "music.mic")
                }
                .help("Open the lyrics display — drag it to a second screen")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onAppear { model.start() }
        .modifier(AlwaysOnTop())
    }
}

/// Keeps a window above other apps while the preference is on.
struct AlwaysOnTop: ViewModifier {
    static let defaultsKey = "alwaysOnTop"

    @AppStorage(AlwaysOnTop.defaultsKey) private var onTop = false
    @State private var host = WindowHolder()

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window in
                host.window = window
                apply()
            })
            .onChange(of: onTop) { _, _ in apply() }
    }

    private func apply() {
        host.window?.level = onTop ? .floating : .normal
    }
}

/// Holds the hosting window without participating in SwiftUI's update cycle.
private final class WindowHolder {
    weak var window: NSWindow?
}

/// Grabs the NSWindow hosting this view, so window-level notifications can be
/// matched to the right window.
///
/// Fires **once per window**. `updateNSView` runs on every SwiftUI update, so
/// calling back each time re-applies window configuration continuously — which
/// is visible as the title-bar buttons flickering.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    final class Coordinator {
        weak var resolved: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window yet during makeNSView.
        DispatchQueue.main.async { resolve(view, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { resolve(view, context.coordinator) }
    }

    private func resolve(_ view: NSView, _ coordinator: Coordinator) {
        guard let window = view.window, window !== coordinator.resolved else { return }
        coordinator.resolved = window
        onResolve(window)
    }
}

/// Panel surface that takes on the cover's colour. Kept low-opacity over the
/// dark base so white text keeps its contrast on bright artwork.
private struct TintedPanel: View {
    let tint: Color
    var strength: Double = 0.22

    var body: some View {
        ZStack {
            Theme.panel
            LinearGradient(
                colors: [tint.opacity(strength), tint.opacity(strength * 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Header

private struct NowPlayingHeader: View {
    @EnvironmentObject private var model: KaraokeModel
    var artworkSize: CGFloat = 38
    var centred: Bool = false

    var body: some View {
        Group {
            if centred {
                VStack(spacing: 16) {
                    artwork
                    VStack(spacing: 5) {
                        title.font(.system(size: 22, weight: .semibold, design: .rounded))
                        artist.font(.system(size: 15, weight: .medium, design: .rounded))
                    }
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 14) {
                    artwork
                    VStack(alignment: .leading, spacing: 3) {
                        title.font(.system(size: 15, weight: .semibold, design: .rounded))
                        artist.font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, centred ? 20 : 12)
    }

    private var title: some View {
        Text(model.track?.name ?? "Nothing playing")
            .foregroundStyle(.white)
            // reservesSpace: a one-line title after a two-line one would
            // otherwise change the header's height on every skip.
            .lineLimit(2, reservesSpace: true)
    }

    private var artist: some View {
        Text(model.track?.artist ?? "—")
            .foregroundStyle(Theme.upcoming)
            .lineLimit(1)
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let url = model.track?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.backdrop
                }
            } else {
                Theme.backdrop
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(shape)
        .overlay(shape.stroke(Theme.hairline))
        .shadow(color: .black.opacity(artworkSize > 80 ? 0.45 : 0), radius: 18, y: 6)
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Position bar you can drag to seek. Redraws off its own TimelineView because
/// the clock isn't @Published — polling only republishes twice a second, which
/// would make the playhead visibly step rather than glide.
private struct Scrubber: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: FrameRate.interval(for: targetFPS),
                                paused: !model.isPlaying)) { _ in
            let duration = max(1, model.track?.duration ?? 1)
            let live = min(1, max(0, model.clock.position / duration))
            let fraction = scrub ?? live

            // Times flank the bar so it can run the full width of the window.
            HStack(spacing: 12) {
                Text(Self.timecode(fraction * duration))
                    .font(Theme.timecode)
                    .foregroundStyle(scrub == nil ? Theme.upcoming : Theme.cue)
                    .frame(width: 42, alignment: .trailing)

                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.hairline)
                            .frame(height: 6)
                        Capsule()
                            .fill(model.palette.accent)
                            .frame(width: width * fraction, height: 6)
                        Circle()
                            .fill(.white)
                            .frame(width: scrub == nil ? 11 : 14, height: scrub == nil ? 11 : 14)
                            .offset(x: width * fraction - (scrub == nil ? 5.5 : 7))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        // minimumDistance 0 so a plain click seeks too.
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                scrub = min(1, max(0, value.location.x / width))
                            }
                            .onEnded { value in
                                let target = min(1, max(0, value.location.x / width))
                                // Seek only on release — every seek is an Apple
                                // Event, and firing one per drag sample floods it.
                                model.seek(to: target * duration)
                                scrub = nil
                            })
                }
                .frame(height: 16)

                Text(Self.timecode(duration))
                    .font(Theme.timecode)
                    .foregroundStyle(Theme.upcoming)
                    .frame(width: 42, alignment: .leading)
            }
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Controls

private struct ControlBar: View {
    @EnvironmentObject private var model: KaraokeModel
    @Binding var fontSize: Double
    @Binding var showSearch: Bool
    /// Manual entry asks one question at a time, in place, rather than opening
    /// a window: letter, then accidental, then major/minor, then BPM.
    private enum Step: Equatable { case idle, letter, accidental, quality, tempo }
    @State private var step: Step = .idle
    @State private var letter = "C"
    @State private var accidental = ""
    @State private var isMinor = false
    @State private var bpmField = ""
    @FocusState private var bpmFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let status = model.status {
                Text(status)
                    .font(Theme.label)
                    .foregroundStyle(Theme.cue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            ViewThatFits(in: .horizontal) {
                singleRow
                stackedRows
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, model.track == nil ? 12 : 6)

            if model.track != nil {
                Scrubber()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        // Slightly stronger than the window behind it so the bar still reads as
        // its own surface, capped so bright covers can't wash out the labels.
        .background(TintedPanel(tint: model.palette.accent,
                                strength: min(0.20, model.palette.tintStrength * 1.4)))
        .animation(.easeInOut(duration: 1.2), value: model.palette)
    }

    /// Everything on one line — used whenever the window is wide enough.
    private var singleRow: some View {
        HStack(spacing: 18) {
            searchButton
            Divider().frame(height: 18).overlay(Theme.hairline)
            transportGroup
            Spacer()
            musicalInfo
            fontStepper
        }
    }

    /// Narrow windows: transport keeps prominence on its own line, with the
    /// readouts and adjustments beneath it.
    private var stackedRows: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                searchButton
                Spacer()
                transportGroup
                Spacer()
                fontStepper
            }
            HStack(spacing: 14) {
                Spacer()
                musicalInfo
            }
        }
    }

    private var searchButton: some View {
        Button { showSearch = true } label: {
            Label("Find a song", systemImage: "magnifyingglass")
        }
        .buttonStyle(.borderless)
    }

    private var transportGroup: some View {
        HStack(spacing: 10) {
            transport("backward.end.fill") { model.previousTrack() }
            transport(model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlayback() }
            transport("forward.end.fill") { model.nextTrack() }
        }
    }

    private func transport(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
    }

    /// Key and tempo, editable in place, one question at a time.
    private var musicalInfo: some View {
        Group {
            switch step {
            case .idle:       readout
            case .letter:     letterStep
            case .accidental: accidentalStep
            case .quality:    qualityStep
            case .tempo:      tempoStep
            }
        }
        .frame(width: 268, alignment: .trailing)
        .padding(.trailing, 4)
        .animation(.easeInOut(duration: 0.18), value: step)
        .animation(.easeInOut(duration: 0.25), value: model.publishedAnalysis)
    }

    /// Normal display, identical whether the values came from an API or by hand.
    @ViewBuilder
    private var readout: some View {
        let analysis = model.publishedAnalysis
        let suspect = analysis?.halfTimeSuspect == true

        if analysis == nil {
            Button {
                beginEntry()
            } label: {
                Label("Set key / BPM", systemImage: "plus.circle")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.upcoming)
            .help("No source has key or tempo for this track — enter them by hand")
        } else {
            HStack(spacing: 10) {
                // Always rendered, showing "—" when unset, so a field can never
                // silently vanish from the bar once anything has been entered.
                labelledValue("KEY", analysis?.key ?? "—")
                    .foregroundStyle(model.manualKey != nil ? Theme.cue : .white)

                HStack(spacing: 5) {
                    labelledValue("BPM", Self.bpmText(analysis?.tempo))
                        .foregroundStyle(model.manualTempo != nil ? Theme.cue : .white)

                    if suspect {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.cue)
                            .help("The two sources disagree by 2× — this may be half-time. Use ×2 or ÷2 to correct it.")
                    }
                }

                HStack(spacing: 4) {
                    tempoButton("÷2", to: model.tempoMultiplier / 2,
                                active: model.tempoMultiplier < 1)
                    tempoButton("×2", to: model.tempoMultiplier * 2,
                                active: model.tempoMultiplier > 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { beginEntry() }
            .help("Click to set the key and tempo by hand")
        }
    }

    private static func bpmText(_ tempo: Double?) -> String {
        guard let tempo, tempo > 0 else { return "—" }
        return String(format: "%.0f", tempo)
    }

    // MARK: Entry steps

    private var letterStep: some View {
        HStack(spacing: 3) {
            ForEach(["A", "B", "C", "D", "E", "F", "G"], id: \.self) { note in
                chip(note) {
                    letter = note
                    step = .accidental
                }
            }
            if model.hasManualValues {
                chip("Auto", width: 38) {
                    model.manualKey = nil
                    model.manualTempo = nil
                    step = .idle
                }
            }
            cancelChip
        }
    }

    private var accidentalStep: some View {
        HStack(spacing: 4) {
            stepLabel(letter)
            // Natural is offered alongside sharp and flat: without it, plain C,
            // D, E, F, G, A and B — the most common keys — are unreachable.
            chip("♮", width: 34) { accidental = ""; step = .quality }
            chip("♯", width: 34) { accidental = "♯"; step = .quality }
            chip("♭", width: 34) { accidental = "♭"; step = .quality }
            cancelChip
        }
    }

    private var qualityStep: some View {
        HStack(spacing: 4) {
            stepLabel(letter + accidental)
            chip("major", width: 54) { isMinor = false; step = .tempo }
            chip("minor", width: 54) { isMinor = true; step = .tempo }
            cancelChip
        }
    }

    private var tempoStep: some View {
        HStack(spacing: 5) {
            stepLabel(letter + accidental + (isMinor ? "m" : ""))

            Text("BPM")
                .font(Theme.label)
                .foregroundStyle(Theme.upcoming)

            TextField("120", text: $bpmField)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .focused($bpmFocused)
                .onSubmit { commit() }

            chip("Save", width: 46) { commit() }
            cancelChip
        }
        .onAppear { bpmFocused = true }
    }

    // MARK: Entry plumbing

    private func beginEntry() {
        // Seed from whatever is showing, so an override starts from the current
        // value rather than from scratch.
        if let key = model.publishedAnalysis?.key, let first = key.first {
            letter = String(first)
            accidental = key.contains("♯") ? "♯" : (key.contains("♭") ? "♭" : "")
            isMinor = key.hasSuffix("m")
        }
        if let tempo = model.publishedAnalysis?.tempo, tempo > 0 {
            bpmField = String(format: "%.0f", tempo)
        }
        step = .letter
    }

    private func commit() {
        model.manualKey = letter + accidental + (isMinor ? "m" : "")
        let trimmed = bpmField.trimmingCharacters(in: .whitespaces)
        model.manualTempo = trimmed.isEmpty ? nil : Double(trimmed)
        bpmFocused = false
        bpmField = ""
        step = .idle
    }

    private var cancelChip: some View {
        chip("✕", width: 24) {
            bpmFocused = false
            step = .idle
        }
    }

    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.cue)
            .frame(minWidth: 26)
    }

    private func chip(_ label: String, width: CGFloat = 26,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: width, height: 22)
                .background(Color.white.opacity(0.13),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tempoButton(_ label: String, to multiplier: Double, active: Bool) -> some View {
        Button {
            model.tempoMultiplier = min(4, max(0.25, multiplier))
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? Theme.backdrop : .white.opacity(0.75))
                .frame(width: 32, height: 22)
                .background(active ? Theme.cue : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(multiplier < 0.25 || multiplier > 4)
        .help(model.tempoMultiplier == 1
              ? "Halve or double the tempo sent to Logic"
              : String(format: "Correction ×%.2g — click the other to undo", model.tempoMultiplier))
    }

    private func labelledValue(_ caption: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(caption)
                .font(Theme.label)
                .foregroundStyle(Theme.upcoming)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var fontStepper: some View {
        HStack(spacing: 6) {
            Button { fontSize = max(24, fontSize - 4) } label: { Image(systemName: "textformat.size.smaller") }
                .buttonStyle(.borderless)
            Button { fontSize = min(96, fontSize + 4) } label: { Image(systemName: "textformat.size.larger") }
                .buttonStyle(.borderless)
        }
        .foregroundStyle(Theme.upcoming)
    }
}

// MARK: - Empty states

struct StageMessage: View {
    let title: String
    var detail: String?
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            if let detail {
                Text(detail)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.sung)
                    .foregroundStyle(Theme.backdrop)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
