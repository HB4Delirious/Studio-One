import SwiftUI

// The smaller Settings panes. Logic has its own file; Accounts lives in
// SettingsSheet with the footer that saves its keys; Rig check in RigCheck,
// with the log from here at its foot.

struct KeyAndTempoSettings: View {
    @AppStorage(KaraokeModel.copyOnMissKey) private var copyOnMiss = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Key and tempo")

            // GetSongBPM's terms require this link to be visible in the app.
            SettingsSection("Where they come from", divided: false, info: "Key and tempo come from ReccoBeats first, which needs no key. GetSongBPM fills in what ReccoBeats is missing — add a free API key under Accounts to enable it. When neither has a song, Studio One listens to its 30-second preview from Apple's or Deezer's catalogue and works the key and tempo out on this Mac, and sends its best reading.") {
                Text("ReccoBeats, then GetSongBPM, then the song's preview, worked out on this Mac.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                Link("Powered by GetSongBPM", destination: URL(string: "https://getsongbpm.com")!)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.cue)
            }

            SettingsSection("When nothing is found") {
                Toggle("Copy the track name, ready to search for it", isOn: $copyOnMiss)
                    .font(.system(size: 12, design: .rounded))
                Text("Or set them by hand: click the key and BPM under the song's title in the Controls window.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// What the Stream Deck's dials drive in Logic, and the plug-in settings kept
/// per song.
struct MixerSettings: View {
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @AppStorage(PitchPlugin.tunerCountKey) private var tunerCount = 1
    @AppStorage(MixerControl.stepKey) private var mixerStep = MixerControl.Step.signMagnitude.rawValue

    /// Settings › Mixer & songs: what the Stream Deck's dials drive, and the
    /// plug-in settings kept per song — all of it sent through the MIDI port,
    /// so with that off there's one card to turn it on rather than a form that
    /// can't be used.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Mixer and per-song settings")
            if midiEnabled {
                mixerSection
                SongControlSettings()
            } else {
                SettingsSection("") {
                    Text("The Stream Deck's mic dials and the per-song plug-in settings reach Logic through Studio One's MIDI port, which is off.")
                        .font(.system(size: 12, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Turn On “Send key and tempo as MIDI”") { midiEnabled = true }
                        .controlSize(.small)
                }
            }
        }
    }

    /// The mic-channel controls the Stream Deck's dials drive.
    private var mixerSection: some View {
        SettingsSection("Mic channels in Logic", info: "For the Stream Deck's dials. Each one sends a step rather than a position, so Logic moves the fader from where it is — no jumps, and nothing to catch up with. Learn each control in Logic's Controller Assignments (⌥⇧K), aiming it at that mic's channel strip. All of these travel on MIDI channel \(MixerControl.channel + 1), so they can't collide with the key and tempo. The four plug-in slots are whatever you learn them to — MetaTune's speed or humanize, a gate threshold, anything Logic can learn.") {
            ForEach(1...max(1, tunerCount), id: \.self) { mic in
                let controls = MixerControl.all.filter { $0.mic == mic }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([controls.filter { !$0.id.contains("plugin") },
                             controls.filter { $0.id.contains("plugin") }], id: \.first) { row in
                        HStack(spacing: 6) {
                            Text(row.first?.id.contains("plugin") == true ? "" : "Mic \(mic)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .frame(width: 44, alignment: .leading)
                            ForEach(row) { control in
                                Button(control.name.components(separatedBy: " · ").last ?? control.name) {
                                    MIDIBridge.shared.sendMixerForLearn(control)
                                }
                                .help("CC \(control.cc), channel \(MixerControl.channel + 1)")
                            }
                        }
                    }
                }
                .controlSize(.small)
            }

            LabelledRow("Dial steps:") {
                Picker("Dial steps", selection: $mixerStep) {
                    ForEach(MixerControl.Step.allCases) { step in
                        Text(step.displayName).tag(step.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .info("In Logic's Expert view, a dial wants Mode: Relative and Format: \(MixerControl.Step(rawValue: mixerStep)?.logicFormat ?? "Sign Magnitude"); Mute wants Mode: Toggle. If a fader jumps to an end instead of nudging, that pair is what's wrong — or switch the format above.")
        }
    }
}

struct DisplaySettings: View {
    @AppStorage(LyricsStyle.defaultsKey) private var lyricsStyle: LyricsStyle = .highlight
    @AppStorage(SingerBanner.enabledKey) private var singerBanner = true
    @AppStorage(NetEaseLyrics.enabledKey) private var netEase = true
    @AppStorage(StagePreview.enabledKey) private var stagePreview = true
    @AppStorage(MenuBarReadout.enabledKey) private var menuBarReadout = true
    @AppStorage(AlwaysOnTop.defaultsKey) private var alwaysOnTop = false
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Display")

            SettingsSection("Lyrics", divided: false) {
                Picker("Lyrics", selection: $lyricsStyle) {
                    ForEach(LyricsStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(lyricsStyle.detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                Group {
                    Toggle("Show who's singing now and next on the lyrics screen", isOn: $singerBanner)
                        .help("Guests' names come from the request line; the next song from the player's queue")
                    Toggle("When LRCLIB has no timed lyrics, try NetEase Cloud Music", isOn: $netEase)
                        .help("Often timed word by word. Not an official API, so it may stop working without notice.")
                }
                .font(.system(size: 12, design: .rounded))
            }

            // One font for every switch: the last one here had its own, a
            // size smaller than the rest.
            SettingsSection("Windows") {
                Group {
                    Toggle("Show the lyrics display in the controls window", isOn: $stagePreview)
                        .help("A live thumbnail of what the room is seeing, in place of the album art")
                    Toggle("Show key and BPM in the menu bar", isOn: $menuBarReadout)
                        .help("Readable without bringing a window forward")
                    Toggle("Keep windows above other apps", isOn: $alwaysOnTop)
                }
                .font(.system(size: 12, design: .rounded))
            }

            SettingsSection("Frame rate") {
                // Nothing to choose on screens that only go to 60: one line,
                // until a faster one is connected.
                if FrameRate.displayMaximum <= FrameRate.minimum {
                    Text("Lyrics and the position bar redraw at \(Int(FrameRate.displayMaximum)) fps, the most these screens show. Connect a faster one, such as a 120 Hz TV, to choose more.")
                        .font(.system(size: 12, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    frameRateChooser
                }
            }
        }
    }

    private var frameRateChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Lyrics and the position bar redraw at")
                        .font(.system(size: 12, design: .rounded))
                    Spacer()
                    Text("\(Int(targetFPS)) fps")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Slider(value: $targetFPS,
                       in: FrameRate.minimum...FrameRate.selectableMaximum,
                       step: 10)

                Text(FrameRate.displayMaximum >= targetFPS
                     ? "This display runs at \(Int(FrameRate.displayMaximum)) fps."
                     : "This display runs at \(Int(FrameRate.displayMaximum)) fps, so the extra frames only appear once a faster display is connected.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StreamDeckSettings: View {
    @State private var streamDeckMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneTitle("Stream Deck")

            SettingsSection("") {
            // The status sat at the end of the button row and squeezed both
            // buttons' titles down to "Install the Stream D…".
            if let port = ControlServer.shared.port {
                Label("Listening on this Mac, port \(String(port))", systemImage: "checkmark.circle.fill")
                    .font(Theme.label).foregroundStyle(Theme.cue)
            } else {
                Label("Control port not running", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.label).foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button("Install the Stream Deck Plug-in") {
                    streamDeckMessage = StreamDeckInstaller.install() ?? "Handed to the Stream Deck app — confirm there if it asks."
                }
                .fixedSize()
                Button("Add the Stream Deck + Page") {
                    streamDeckMessage = StreamDeckInstaller.installPage()
                        ?? "Handed to the Stream Deck app. Keys: play, previous, next, key & BPM, both mic mutes, full-screen lyrics, now playing. Dials: Mic 1 and 2 level and plug-in 1; swipe the strip for key, tempo, lyric sync and volume."
                }
                .fixedSize()
                .help("A ready-made two-page layout for Stream Deck +. Install the plug-in first.")
            }
            if let message = streamDeckMessage {
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }

            SettingsSection("Keys and dials", info: "KEYS\nPlay/Pause · Next · Previous · Fade Out · Now Playing (album art; opens the lyrics) · Key & BPM (sends the key to Logic) · Lyrics Full Screen · Switch Source · Reload Lyrics · Logic Mic Mute · MIDI Button\n\nDIALS (Stream Deck+)\nKey — turn to transpose, press to reset, touch to send to Logic\nTempo — ±1 BPM, press to reset, tap ×2, hold ÷2\nLyric Sync — ±50 ms, press to reset, tap the strip as a line starts to sync, hold to reload\nVolume — ±2, press to mute\nSeek — ±5 s, press to play/pause, tap next, hold previous\nLyric Size — ±2 pt, press to reset\nLogic Mic Dial — a mic's level, send or plug-in control, press to mute that mic\nMIDI Dial — any controller and channel you choose\n\nThe Logic and MIDI actions work with Studio One closed: the deck sends the MIDI itself, on the same port Logic already knows.\n\nThe plug-in talks to Studio One on 127.0.0.1 only, with a key kept in a file only your account can read, so nothing else on the network can drive playback.") {
                Text("After installing, find “Studio One” in the Stream Deck app's actions and drag them onto your keys and dials — nothing needs setting up.")
                    .font(.system(size: 12, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Rig check's last section: the log, to send when something's wrong.
struct LogSection: View {
    @State private var logNotice: String?

    var body: some View {
        SettingsSection("Log") {
            HStack(spacing: 8) {
                Button("Copy Log") {
                    logNotice = Diagnostics.copyToClipboard()
                        ? "Log copied — paste it into a message."
                        : "Couldn't read the log yet."
                }
                Button("Save to Desktop") {
                    logNotice = Diagnostics.saveToDesktop().map { "Saved as “\($0.lastPathComponent)”." }
                        ?? "Couldn't write to the Desktop."
                }
                Button("Reveal") { Diagnostics.reveal() }
            }
            .controlSize(.small)

            Text(logNotice ?? "Records the machine, track changes, lookups and errors. No credentials.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(logNotice == nil ? Theme.secondary : Theme.cue)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
