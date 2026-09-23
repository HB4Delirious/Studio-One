import SwiftUI
import AppKit

/// The lyrics display, on its own so it can live full-screen on a second screen
/// or a TV while the controls stay on your main display.
struct LyricsWindow: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage("lyricFontSize") private var fontSize: Double = 42
    @Environment(\.openWindow) private var openWindow
    @State private var isFullScreen = false
    // A reference box, deliberately not @State holding the window itself:
    // assigning an NSWindow to @State invalidates the view, which re-runs
    // updateNSView, which assigns again — an update loop that made the green
    // button strobe between zoom and full screen.
    @State private var host = WindowHolder()

    var body: some View {
        LyricsPane(fontSize: CGFloat(fontSize))
            .frame(minWidth: 480, minHeight: 320)
            .preferredColorScheme(.dark)
            // Full screen is the performance view: nothing but lyrics.
            .toolbar(isFullScreen ? .hidden : .visible, for: .windowToolbar)
            .background(WindowReader { window in
                host.window = window
                // SwiftUI marks the first scene primary and every later scene
                // *auxiliary*, and an auxiliary window's green button offers zoom
                // (+) rather than full screen. Inserting fullScreenPrimary alone
                // does nothing while the auxiliary flag is still set — this
                // window became secondary when the controls became the launch
                // window, which is exactly when full screen stopped working.
                window.collectionBehavior.remove(.fullScreenAuxiliary)
                window.collectionBehavior.remove(.fullScreenNone)
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

}

/// Transport, track info, sync and settings — everything that isn't the lyrics.
/// The compact control strip this window used to be, before it became the
/// library browser. Kept because it is the whole layout in one view: pointing
/// the Controls scene back at `ControlsWindow()` restores it.
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

    /// Runs on every update rather than once per window. Window configuration
    /// applied a single time at startup can be overwritten by SwiftUI afterwards
    /// — which is how full-screen capability kept reverting to a plain zoom
    /// button. Re-applying is safe now: the window lives in a reference box, so
    /// storing it doesn't invalidate the view and can't loop.
    private func resolve(_ view: NSView, _ coordinator: Coordinator) {
        guard let window = view.window else { return }
        let isNew = window !== coordinator.resolved
        coordinator.resolved = window
        onResolve(window)

        if isNew {
            Diagnostics.log("window \"\(window.title)\": fullScreenPrimary=\(window.collectionBehavior.contains(.fullScreenPrimary)) resizable=\(window.styleMask.contains(.resizable))")
        }
    }
}

/// Panel surface that takes on the cover's colour. Kept low-opacity over the
/// dark base so white text keeps its contrast on bright artwork.
struct TintedPanel: View {
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

struct NowPlayingHeader: View {
    @EnvironmentObject private var model: KaraokeModel
    var artworkSize: CGFloat = 38
    var centred: Bool = false
    /// Dropped when the stage preview is showing above it — two pictures of the
    /// same song stacked in a 336-point column is one too many.
    var showArtwork: Bool = true

    var body: some View {
        Group {
            if centred {
                VStack(spacing: 16) {
                    if showArtwork { artwork }
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
        // A space, not a dash, when nothing plays: the line keeps its height
        // so the header doesn't jump, without a stray mark under the title.
        Text(model.track?.artist ?? " ")
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
            } else if let image = model.localArtwork {
                Image(nsImage: image).resizable().scaledToFill()
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
struct Scrubber: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: FrameRate.interval(for: targetFPS),
                                paused: !model.isPlaying)) { _ in
            let hasTrack = (model.track?.duration ?? 0) > 0
            let duration = max(1, model.track?.duration ?? 1)
            let live = hasTrack ? min(1, max(0, model.clock.position / duration)) : 0
            let fraction = scrub ?? live

            // Times flank the bar so it can run the full width of the window.
            HStack(spacing: 12) {
                // Nothing playing reads as blank, not as a one-second song.
                Text(hasTrack ? Self.timecode(fraction * duration) : "–:––")
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
                            .opacity(hasTrack ? 1 : 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .allowsHitTesting(hasTrack)
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

                Text(hasTrack ? Self.timecode(duration) : "–:––")
                    .font(Theme.timecode)
                    .foregroundStyle(Theme.upcoming)
                    .frame(width: 42, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue(hasTrack ? "\(Self.timecode(fraction * duration)) of \(Self.timecode(duration))" : "Nothing playing")
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Controls

struct ControlBar: View {
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
            sourceSwitch
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
                sourceSwitch
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

    /// Which player drives the app. Switching rebuilds the controller live.
    private var sourceSwitch: some View {
        Picker("", selection: Binding(
            get: { model.musicSource },
            set: { model.changeSource(to: $0) })) {
                ForEach(MusicSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 168)
            .help("Follow Spotify or Apple Music")
    }

    private var transportGroup: some View {
        HStack(spacing: 10) {
            transport("backward.end.fill", "Previous track") { model.previousTrack() }
            transport(model.isPlaying ? "pause.fill" : "play.fill",
                      model.isPlaying ? "Pause" : "Play") { model.togglePlayback() }
            transport("forward.end.fill", "Next track") { model.nextTrack() }
        }
    }

    /// The label matters: the symbols' own descriptions are backwards here —
    /// VoiceOver read "previous" as "Go To End" and "next" as "Go To Start".
    private func transport(_ symbol: String, _ label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
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
                    labelledValue("BPM", TrackAnalysis.bpmText(analysis?.tempo))
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
        // Through the same reading MIDI uses. Taken apart by hand, "Eb" seeded
        // a plain E and "A minor" a major key, so opening the editor and
        // pressing Done could change the key without anyone touching it.
        if let key = model.publishedAnalysis?.key, let coded = MIDIBridge.encode(key: key) {
            let name = MIDIBridge.decode(root: coded.root, minor: false)
            letter = String(name.prefix(1))
            accidental = name.contains("♯") ? "♯" : ""
            isMinor = coded.minor
        }
        if let tempo = model.publishedAnalysis?.tempo, tempo > 0 {
            bpmField = String(format: "%.0f", tempo)
        }
        step = .letter
    }

    private func commit() {
        model.manualKey = letter + accidental + (isMinor ? "m" : "")
        // Empty clears the tempo. Anything else has to read as a plausible
        // tempo: "120,5" or a typo used to become nil too, quietly erasing a
        // tempo set earlier, and "0" or "5000" went straight out to Logic.
        let trimmed = bpmField.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.manualTempo = nil
        } else if let typed = Double(scripted: trimmed), typed.isFinite {
            model.manualTempo = min(400, max(20, (typed * 10).rounded() / 10))
        }
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
            // The glyphs are a few points across; the frames make each one a
            // target a finger on a trackpad can actually hit.
            Button { fontSize = max(24, fontSize - 4) } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Smaller lyrics")
            .help("Smaller lyrics")
            Button { fontSize = min(96, fontSize + 4) } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Larger lyrics")
            .help("Larger lyrics")
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
                // Drawn by hand: a prominent system button greys out when its
                // window isn't the active one, and the lyrics window almost
                // never is — it sits on the second screen while you work in
                // Controls, where this read as a disabled, near-black button.
                Button(action: action.1) {
                    Text(action.0)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.backdrop)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.sung))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
