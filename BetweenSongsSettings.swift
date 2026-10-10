import SwiftUI

/// Settings › Between Songs: the break after each song, fading a song out
/// early and the time limit that does it for you, and the applause meter
/// that listens to the room during the break.
struct BetweenSongsSettings: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(BreakMode.defaultsKey) private var mode: BreakMode = .off
    @AppStorage(HouseMusic.enabledKey) private var houseOn = false
    @AppStorage(HouseMusic.levelKey) private var houseLevel = 40.0
    @AppStorage(HouseMusic.duringBreaksKey) private var houseDuringBreaks = true
    @AppStorage(HouseMusic.whenEmptyKey) private var houseWhenEmpty = true
    @State private var housePlaylists: [LibraryPlaylist] = []
    @State private var houseChoice = HouseMusic.playlist
    @AppStorage(FadeOut.lengthKey) private var fadeLength = 5.0
    @AppStorage(FadeOut.limitKey) private var timeLimit = 0.0
    @AppStorage(Applause.enabledKey) private var applauseOn = false
    @AppStorage(Applause.deviceKey) private var device = ""
    @AppStorage(Applause.floorKey) private var floor = Applause.defaultFloor
    @ObservedObject private var applause = Applause.shared
    @State private var inputs: [Applause.Input] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Between Songs")

            SettingsSection("Break", info: "Only a song that plays to its end starts a break; Next, Previous or picking a song moves on straight away. Play — in Studio One, on the Stream Deck or on your remote — starts the next song during a break, and the Controls window has Start Next Song and +30 s.") {
                LabelledRow("After each song:") {
                    Picker("Break", selection: $mode) {
                        ForEach(BreakMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Text(mode == .off
                     ? "Songs run straight into each other."
                     : "As a song ends, the music pauses and the lyrics screen shows who's up next, with the code to request a song. "
                        + (mode == .untilPlay ? "Play starts the next song." : "The next song starts by itself, or sooner with Play."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("Fade out", info: "A fade takes the player's volume down, pauses the song at silence and puts the volume back, then starts the break or the next song. Play, Next or Cancel during a fade stops it and puts the volume back. A song less than 20 seconds over the limit is left to finish; with timed lyrics, the fade waits up to 15 seconds for the line being sung to end.") {
                LabelledRow("Fade over:") {
                    Picker("Fade over", selection: $fadeLength) {
                        ForEach(FadeOut.lengths, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                LabelledRow("Time limit:") {
                    Picker("Time limit", selection: $timeLimit) {
                        ForEach(FadeOut.limits, id: \.self) { Text(FadeOut.limitTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(timeLimit > 0
                     ? "Songs fade out after \(FadeOut.limitTitle(timeLimit)), as the line being sung ends. Let It Play in the Controls window keeps one going."
                     : "Fade Out in the Controls window, ⌥⌘→, the Stream Deck or your remote ends a song gently.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("House music", info: "A playlist of your own between singers, quieter than the singing. During a break it starts once the cheer has been heard; Studio One notes the next song in the queue first and plays it when the break ends. With nothing queued, it plays until a guest requests a song, which then starts. Picking a song yourself takes over at once. House music never ends a break, isn't sent to Logic, isn't kept in History and doesn't show on the lyrics screen; with Spotify, coming back to the queue needs you signed in.") {
                Toggle("Play house music between singers", isOn: $houseOn)
                    .font(.system(size: 12, design: .rounded))
                if houseOn {
                    LabelledRow("Playlist:") {
                        Picker("Playlist", selection: Binding(
                            get: { houseChoice },
                            set: { houseChoice = $0; HouseMusic.playlist = $0 })) {
                            Text("Choose…").tag(HouseMusic.Choice?.none)
                            ForEach(housePlaylists) { playlist in
                                Text(playlist.name).tag(Optional(HouseMusic.Choice(playlist)))
                            }
                            if let choice = houseChoice, !housePlaylists.contains(where: choice.matches) {
                                Text(choice.name).tag(Optional(choice))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    LabelledRow("Volume:") {
                        Slider(value: $houseLevel, in: 10...80, step: 5).frame(width: 200)
                        Text("\(Int(houseLevel))% of the singing")
                            .font(Theme.timecode).foregroundStyle(Theme.secondary)
                    }
                    Toggle("During breaks", isOn: $houseDuringBreaks)
                        .font(.system(size: 12, design: .rounded))
                    Toggle("When nothing is queued", isOn: $houseWhenEmpty)
                        .font(.system(size: 12, design: .rounded))
                }
            }
            .task(id: houseOn) {
                guard houseOn, housePlaylists.isEmpty, let browser = model.browser else { return }
                housePlaylists = (try? await browser.playlists()) ?? []
            }

            SettingsSection("Applause meter", info: "During the break, Studio One listens for eight seconds and scores the loudest stretch out of 100; the score shows on the lyrics screen with tonight's loudest three, and stays with the song in History. Set Quiet room with the room as it is between songs, so the meter just rests at the left; a big cheer should reach the right. It listens only then, and while this pane is open, and keeps nothing it hears (recording singers is a setting of its own, in Recordings). macOS asks once for the microphone.") {
                Toggle("Score the cheer after each song", isOn: $applauseOn)
                    .onChange(of: applauseOn) { _, on in
                        on ? applause.startMonitoring() : applause.stopMonitoring()
                    }
                if applauseOn {
                    LabelledRow("Listen on:") {
                        Picker("Input", selection: $device) {
                            Text("The Mac's default input").tag("")
                            ForEach(inputs) { Text($0.name).tag($0.uid) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: device) { _, _ in applause.restart() }
                    }
                    level
                    LabelledRow("Quiet room:") {
                        Slider(value: $floor, in: -75 ... -25, step: 1)
                            .frame(width: 220)
                        Text("\(Int(floor)) dB")
                            .font(Theme.timecode)
                            .foregroundStyle(Theme.secondary)
                    }
                    if let problem = applause.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if mode == .off, applauseOn {
                    Text("The meter needs a break to listen in: choose one above.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            inputs = Applause.inputDevices()
            if applauseOn { applause.startMonitoring() }
        }
        .onDisappear {
            if applauseOn { applause.stopMonitoring() }
        }
    }

    /// The room now, against the floor: what a cheer would score.
    private var level: some View {
        HStack(spacing: 10) {
            Text("Now:").font(Theme.label).foregroundStyle(Theme.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.cue, Theme.sung, Theme.part(.both)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * applause.level))
                }
            }
            .frame(width: 260, height: 8)
            Text("\(Int((applause.level * 100).rounded()))")
                .font(Theme.timecode)
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}
