import AppKit
import SwiftUI

/// The first-run assistant: the few choices Studio One needs before a night —
/// the player, Logic and the tuner, the lyrics screen, the room — and where
/// the rest lives. Shown once on a fresh install; Help › Setup Assistant…
/// brings it back.
@MainActor
final class SetupAssistant: ObservableObject {
    static let shared = SetupAssistant()
    static let doneKey = "setupAssistantDone"

    @Published var shown = false

    /// At launch. A Mac that already runs Studio One has its settings, and
    /// isn't asked again.
    func showIfNew() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.doneKey) else { return }
        let established = [MusicSource.defaultsKey, MIDIBridge.enabledKey, PitchPlugin.defaultsKey, BreakMode.defaultsKey]
            .contains { defaults.object(forKey: $0) != nil }
        if established {
            defaults.set(true, forKey: Self.doneKey)
        } else {
            shown = true
        }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        shown = false
    }
}

struct SetupAssistantSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var venues = VenueThemes.shared
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @AppStorage(PitchPlugin.defaultsKey) private var pitchPlugin: PitchPlugin = .original
    @AppStorage(PitchPlugin.tunerCountKey) private var tunerCount = 1
    @AppStorage(BreakMode.defaultsKey) private var breakMode: BreakMode = .off
    @AppStorage(Applause.enabledKey) private var applause = false
    @State private var step = 0

    /// Opens Settings at a pane, once this sheet is gone.
    let openSettings: (SettingsSheet.Tab) -> Void

    private static let steps = ["Welcome", "Music", "Logic", "Lyrics screen", "Between songs", "Done"]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 8) {
                        Image(systemName: index < step ? "checkmark.circle.fill" : index == step ? "circle.inset.filled" : "circle")
                            .foregroundStyle(index <= step ? model.palette.accent : Theme.secondary)
                        Text(title)
                            .font(.system(size: 13, weight: index == step ? .semibold : .regular))
                            .foregroundStyle(index == step ? .primary : .secondary)
                    }
                    .padding(.vertical, 4)
                }
                Spacer()
            }
            .padding(20)
            .frame(width: 170, alignment: .leading)
            .background(Color.primary.opacity(0.04))

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { page }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                Divider()
                HStack {
                    if step < Self.steps.count - 1 {
                        Button("Skip Setup") { SetupAssistant.shared.finish() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    if step > 0 { Button("Back") { step -= 1 } }
                    if step < Self.steps.count - 1 {
                        Button("Continue") { step += 1 }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Done") { SetupAssistant.shared.finish() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 680, height: 470)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0:
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("Welcome to Studio One").font(.system(size: 24, weight: .bold))
            }
            Text("Karaoke on your Mac: the lyrics on the TV in time with the song, each song's key and tempo sent to Logic for the singers' tuners, and a request line for guests' phones.")
            Text("A few questions to get going. Everything here can be changed later in Settings.")
                .foregroundStyle(.secondary)

        case 1:
            heading("Which player has the songs?")
            Picker("Player", selection: Binding(get: { model.musicSource }, set: { model.changeSource(to: $0) })) {
                ForEach(MusicSource.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            Text("Apple Music lets guests request songs from your library. With Spotify, the lyrics, key and tempo work the same; the request line needs Apple Music.")
            Text("The first time Studio One talks to \(model.musicSource.displayName), macOS asks whether it may control it — click OK.")
                .foregroundStyle(.secondary)
            Label(model.connection == .ready ? "Connected to \(model.musicSource.displayName)."
                                             : "Open \(model.musicSource.displayName) and play a song.",
                  systemImage: model.connection == .ready ? "checkmark.circle.fill" : "music.note")
                .foregroundStyle(model.connection == .ready ? Theme.cue : .secondary)

        case 2:
            heading("Logic")
            Toggle("Send each song's key and tempo to Logic", isOn: $midiEnabled)
            if midiEnabled {
                LabelledRow("Tuner:") {
                    Picker("Tuner", selection: $pitchPlugin) {
                        ForEach(PitchPlugin.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                LabelledRow("Mics with a tuner:") {
                    Picker("Mics", selection: $tunerCount) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Text("Logic sees Studio One as a MIDI input called “Studio One”. Settings › Logic walks you through learning the tuner's controls, once.")
                Text("For the plug-in display, a Mackie Control on the “Studio One Display” ports — never on “Studio One”, which carries the key and tempo.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Without Logic, Studio One is a lyrics screen and a request line; turn this on any time in Settings › Logic.")
                    .foregroundStyle(.secondary)
            }

        case 3:
            heading("The lyrics screen")
            Text("Open the Lyrics window, drag it onto the TV and click its green button for full screen. Between songs it shows the break screen; with nothing playing, the standby screen.")
            Button("Open the Lyrics Window") { openWindow(id: StudioOneApp.lyricsWindowID) }
            LabelledRow("Your venue's name:") {
                TextField("Studio One", text: Binding(
                    get: { venues.current.venueName },
                    set: { name in var theme = venues.current; theme.venueName = name; venues.update(theme) }))
                    .frame(width: 220)
            }
            Text("Shown on the standby and break screens. Settings › Venue has the logo, colours and typeface.")
                .foregroundStyle(.secondary)

        case 4:
            heading("Between songs")
            LabelledRow("A break:") {
                Picker("Break", selection: $breakMode) {
                    ForEach(BreakMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Text("A break shows who's up next, with the code to request a song, before the next one starts.")
                .foregroundStyle(.secondary)
            Toggle("Applause meter: score each singer's cheer during the break", isOn: $applause)
                .disabled(breakMode == .off)
            Text("The request line starts from the Controls window's toolbar, Request Line. House music, lights, recordings and games are in Settings when you want them.")
                .foregroundStyle(.secondary)

        default:
            heading("You're set")
            Text("Rig check walks through the rest on the rig itself: a test key on the tuners, the tempo, the Stream Deck, the plug-in display.")
            Button("Open Rig Check") {
                SetupAssistant.shared.finish()
                openSettings(.rigCheck)
            }
            Text("Help › Setup Assistant… brings this back.")
                .foregroundStyle(.secondary)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .bold))
    }
}
