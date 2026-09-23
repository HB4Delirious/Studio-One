import SwiftUI

// MARK: - Search

struct SearchSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.upcoming)

                TextField("Song or artist", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .rounded))
                    .onSubmit { model.runSearch() }
                    .onChange(of: model.searchQuery) { _, _ in model.runSearch() }

                if model.isSearching {
                    ProgressView().controlSize(.small)
                }

                Button("Close") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.upcoming)
            }
            .padding(16)

            Divider().overlay(Theme.hairline)

            if model.searchResults.isEmpty {
                VStack(spacing: 8) {
                    Text(Credentials.isConfigured ? "Search Spotify's catalogue" : "Add your Spotify keys first")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(Credentials.isConfigured
                         ? "Picking a result starts it in the Spotify app."
                         : "Open Settings and paste in a client ID and secret from the Spotify developer dashboard.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.upcoming)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            } else {
                List(model.searchResults) { result in
                    Button {
                        model.play(result)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: result.artworkURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Theme.backdrop
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("\(result.artist) · \(result.album)")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(Theme.upcoming)
                            }
                            .lineLimit(1)

                            Spacer()

                            Text(duration(result.duration))
                                .font(Theme.timecode)
                                .foregroundStyle(Theme.upcoming)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 520, height: 460)
        .background(Theme.panel)
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var songBPMKey = ""
    /// What the keychain held when the sheet opened, to tell an edit from none.
    @State private var stored = (clientID: "", clientSecret: "", songBPM: "")
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @AppStorage(MIDIBridge.clockKey) private var midiClock = false
    @AppStorage(PitchPlugin.defaultsKey) private var pitchPlugin: PitchPlugin = .original
    @AppStorage(PitchPlugin.invertNotesKey) private var invertNotes = false
    @AppStorage(PitchPlugin.tunerCountKey) private var tunerCount = 1
    @AppStorage(MixerControl.stepKey) private var mixerStep = MixerControl.Step.signMagnitude.rawValue
    @State private var learnTuner = 0
    @State private var streamDeckMessage: String?
    @ObservedObject private var bridge = MIDIBridge.shared
    @AppStorage(MIDIBridge.catchUpKey) private var catchUp = true
    @AppStorage(MIDIBridge.mackieSafeKey) private var mackieSafe = false
    @State private var reading: PluginReading?
    @State private var readingBusy = false
    @State private var readingError: String?
    @ObservedObject private var spotify = SpotifySession.shared
    @State private var testRoot = 2
    @State private var testMinor = true
    @AppStorage(AlwaysOnTop.defaultsKey) private var alwaysOnTop = false
    @AppStorage(KaraokeModel.copyOnMissKey) private var copyOnMiss = true
    @AppStorage(MenuBarReadout.enabledKey) private var menuBarReadout = true
    @AppStorage(StagePreview.enabledKey) private var stagePreview = true
    @AppStorage(LyricsStyle.defaultsKey) private var lyricsStyle: LyricsStyle = .highlight
    @AppStorage(SingerBanner.enabledKey) private var singerBanner = true
    @AppStorage(NetEaseLyrics.enabledKey) private var netEase = true
    @State private var logNotice: String?
    @State private var tab: Tab = .accounts
    @State private var revealKeys = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.hairline)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch tab {
                        case .accounts:    accounts
                        case .keyAndTempo: keyAndTempo
                        case .logic:       logicPanel
                        case .display:     displayPanel
                        case .streamDeck:  streamDeckPanel
                        case .rigCheck:    RigCheckPanel()
                        case .diagnostics: diagnostics
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
                }

                Divider().overlay(Theme.hairline)
                // Everything but the keys applies the moment it changes, so the
                // footer is "Done" — a Cancel that cancelled nothing was a trap.
                // Only edited keys wait for a save, and only then is it offered.
                HStack {
                    if credentialsChanged {
                        Text("Your key changes aren't saved yet.")
                            .font(Theme.label)
                            .foregroundStyle(Theme.upcoming)
                    }
                    Spacer()
                    if credentialsChanged {
                        Button("Discard") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("Save changes") { save() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
        }
        .frame(width: 660, height: 470)
        .background(Theme.panel)
        .onAppear {
            clientID = Credentials.read(.clientID) ?? ""
            clientSecret = Credentials.read(.clientSecret) ?? ""
            songBPMKey = Credentials.read(.songBPM) ?? ""
            stored = (clientID, clientSecret, songBPMKey)
        }
    }

    private var credentialsChanged: Bool {
        clientID != stored.clientID || clientSecret != stored.clientSecret || songBPMKey != stored.songBPM
    }

    /// Which pane is showing. The sheet grew a section at a time until it was
    /// taller than a laptop screen; this keeps each one short enough to read.
    private enum Tab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case keyAndTempo = "Key & tempo"
        case logic = "Logic"
        case display = "Display"
        case streamDeck = "Stream Deck"
        case rigCheck = "Rig check"
        case diagnostics = "Diagnostics"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .accounts:    return "key.fill"
            case .keyAndTempo: return "metronome.fill"
            case .logic:       return "pianokeys"
            case .display:     return "macwindow"
            case .streamDeck:  return "dial.medium"
            case .rigCheck:    return "checklist"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 8)

            ForEach(Tab.allCases) { entry in
                Button { tab = entry } label: {
                    HStack(spacing: 9) {
                        Image(systemName: entry.icon)
                            .font(.system(size: 11))
                            .frame(width: 16)
                        Text(entry.rawValue)
                            .font(.system(size: 12.5, design: .rounded))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == entry ? .white : Color.white.opacity(0.72))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(tab == entry ? model.palette.accent.opacity(0.30) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 176)
        .background(Theme.backdrop.opacity(0.45))
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 18) {
Text("Spotify credentials")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            Text("Create an app at developer.spotify.com/dashboard and copy its client ID and secret. They're enough to search Spotify, and they're stored in your login keychain.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                labelled("Client ID") {
                    secret($clientID)
                }
                labelled("Client secret") {
                    secret($clientSecret)
                }
            }

            spotifySignIn

            labelled("GetSongBPM API key") {
                secret($songBPMKey)
            }

            Toggle("Show the keys", isOn: $revealKeys)
                .font(.system(size: 12, design: .rounded))
                .help("They stay hidden by default so this pane is safe to screen-share")
        }
    }

    /// Optional: only needed to see your own playlists, saved songs and queue.
    private var spotifySignIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let name = spotify.name {
                    Label("Signed in to Spotify as \(name)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.cue)
                    Button("Sign out") { spotify.signOut() }
                        .controlSize(.small)
                } else {
                    Button(spotify.busy ? "Waiting for Spotify…" : "Sign in to Spotify") {
                        // The client ID has to be in the keychain before the
                        // browser opens. Not `save()`, which closes this sheet.
                        Credentials.write(clientID.trimmingCharacters(in: .whitespaces), for: .clientID)
                        spotify.signIn()
                    }
                    .disabled(spotify.busy || clientID.isEmpty)
                    if spotify.busy { ProgressView().controlSize(.small) }
                }
            }
            if let error = spotify.error {
                Text(error)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Only for your library: playlists, Liked Songs and the queue. The login happens on Spotify's page in your browser — Studio One never sees your password. First add this Redirect URI to your app in the Spotify dashboard:")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(SpotifyAccount.redirectURI)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyAccount.redirectURI, forType: .string)
                }
                .controlSize(.mini)
            }
        }
    }

    private var keyAndTempo: some View {
        VStack(alignment: .leading, spacing: 18) {
Text("Key and tempo")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            // Spotify's audio-features endpoint returns 403 for apps created
            // after November 2024, so key and tempo come from GetSongBPM instead.
            // Their terms require this link to be visible in the app.
            VStack(alignment: .leading, spacing: 6) {
                Text("Key and tempo come from ReccoBeats first, which needs no key. GetSongBPM fills in what ReccoBeats is missing — add a free API key under Accounts to enable it.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)

                Link("Powered by GetSongBPM", destination: URL(string: "https://getsongbpm.com")!)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.cue)
            }

Toggle("Copy the track name when no key or tempo is found", isOn: $copyOnMiss)
                .font(.system(size: 12, design: .rounded))
        }
    }

    private var logicPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
Text("Send to Logic")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Send key and tempo as MIDI", isOn: $midiEnabled)
                    .font(.system(size: 12, design: .rounded))

                Text("Publishes a MIDI source named “Spot-a-oke” — the old app name, kept so existing Logic assignments keep working. In Logic, open Controller Assignments (⌘K), touch a plug-in parameter, then press the matching Send for Learn button. CC \(MIDIBridge.tempoCC) carries the tempo.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Keep clear of Mackie Control", isOn: $mackieSafe)
                    .font(.system(size: 12, design: .rounded))
                    .disabled(!midiEnabled)
                Text(mackieSafe
                     ? "Key, scale and tempo use CC \(PitchPlugin.rootCC), \(PitchPlugin.modeCC) and \(MIDIBridge.tempoCC)/\(MIDIBridge.tempoFineCC), which a Mackie Control ignores. Assignments learned on the old numbers need learning again."
                     : "Key, scale and tempo use CC \(PitchPlugin.rootCC), \(PitchPlugin.modeCC) and \(MIDIBridge.tempoCC)/\(MIDIBridge.tempoFineCC). On channel 1 a Mackie Control reads CC 16–23 as its knobs; if one is set up in Logic, turn this on (and learn those again). MetaTune's switches are clear either way.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Pitch plug-in", selection: $pitchPlugin) {
                    ForEach(PitchPlugin.listed(keeping: pitchPlugin)) { plugin in
                        Text(plugin.displayName).tag(plugin)
                    }
                }
                .font(.system(size: 12, design: .rounded))
                .frame(maxWidth: 360)
                .disabled(!midiEnabled)

                Text(pluginSetup)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)

                if pitchPlugin.isReadable { readRow }

                HStack(spacing: 8) {
                    Text("Mics with a tuner:")
                        .font(Theme.label)
                        .foregroundStyle(Theme.upcoming)
                    Picker("", selection: $tunerCount) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    Text(tunerCount > 1 ? "Mic 1 on MIDI channel 1, Mic 2 on channel 2…" : "")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.upcoming)
                }
                .disabled(!midiEnabled)

                // Learn Mode has to receive a message while it's listening, and
                // track changes are awkward to time. These send on demand.
                HStack(spacing: 8) {
                    Text("Send for Learn:")
                        .font(Theme.label)
                        .foregroundStyle(Theme.upcoming)
                    if tunerCount > 1 {
                        Picker("", selection: $learnTuner) {
                            ForEach(0..<tunerCount, id: \.self) { Text("Mic \($0 + 1)").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 76)
                    }
                    if pitchPlugin.scheme != .noteSwitches {
                        Button(pitchPlugin == .autoTuneAccess ? "Key" : "Root") {
                            MIDIBridge.shared.sendForLearn(model.analysis, control: .key, tuner: learnTuner)
                        }
                    }
                    if pitchPlugin.scheme == .rootAndMode || reading?.canSendScale == true {
                        Button(pitchPlugin.scheme == .rootAndMode && reading == nil ? "Major/minor" : "Scale") {
                            MIDIBridge.shared.sendForLearn(model.analysis, control: .mode, tuner: learnTuner)
                        }
                    }
                    Button("Tempo") { MIDIBridge.shared.sendForLearn(model.analysis, control: .tempo) }
                }
                .controlSize(.small)
                .disabled(!midiEnabled)
                .onChange(of: tunerCount) { _, count in learnTuner = min(learnTuner, count - 1) }

                if pitchPlugin.scheme == .noteSwitches {
                    // One per note: MetaTune's twelve switches each need their
                    // own assignment, and learn mode binds whatever moves next.
                    HStack(spacing: 4) {
                        ForEach(0..<12, id: \.self) { pitchClass in
                            Button(PitchPlugin.noteNames[pitchClass]) {
                                MIDIBridge.shared.sendForLearn(model.analysis, control: .note(pitchClass),
                                                               tuner: learnTuner)
                            }
                            .help("CC \(PitchPlugin.noteCC(pitchClass))")
                        }
                    }
                    .controlSize(.mini)
                    .disabled(!midiEnabled)

                    Toggle("Notes arrive inverted", isOn: $invertNotes)
                        .font(.system(size: 12, design: .rounded))
                        .disabled(!midiEnabled)
                        .help("Turn on if a test lights exactly the five notes that should be off")
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Check it:")
                            .font(Theme.label)
                            .foregroundStyle(Theme.upcoming)
                        Picker("", selection: $testRoot) {
                            ForEach(0..<12, id: \.self) { Text(PitchPlugin.noteNames[$0]).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 64)
                        Picker("", selection: $testMinor) {
                            Text("major").tag(false)
                            Text("minor").tag(true)
                        }
                        .labelsHidden()
                        .frame(width: 84)
                        Button("Send") { MIDIBridge.shared.sendTest(root: testRoot, minor: testMinor) }
                        Button("Send this song's key") { MIDIBridge.shared.publish(model.publishedAnalysis) }
                            .help("Sends what's playing now, without waiting for the next track")
                    }
                    .controlSize(.small)
                    .disabled(!midiEnabled)

                    Text("\(tunerCount > 1 ? "Every mic's plug-in" : "The plug-in") should read: \(pitchPlugin.expectedReading(root: testRoot, minor: testMinor, reading: reading))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    // What actually left the app — so a plug-in that doesn't
                    // move can be told apart from a key that was never sent.
                    Text("Last sent: \(bridge.lastSent)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.upcoming)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Theme.hairline).padding(.vertical, 4)
                mixerSection

                Toggle("Sweep before each key change", isOn: $catchUp)
                    .font(.system(size: 12, design: .rounded))
                    .disabled(!midiEnabled)
                    .help("Logic's Pickup mode ignores a jump straight to a new value; a quick sweep through every value gets past it, as the Learn button does. The plug-in flicks through keys for about a third of a second at each song change.")

                Toggle("Also send MIDI beat clock", isOn: $midiClock)
                    .font(.system(size: 12, design: .rounded))
                    .disabled(!midiEnabled)

                Text("Only followed when Logic is set to external sync — which slaves its transport as well as its tempo. Leave off if you're tracking into an arranged session.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Theme.hairline)
                SongControlSettings()

                Divider().overlay(Theme.hairline)
                LogicBackupSettings()
            }
        }
    }

    /// Ask the installed plug-in how its key and scale menus are laid out.
    private var readRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button(readingBusy ? "Reading…" : "Read \(pitchPlugin.displayName) on this Mac") {
                    readingBusy = true
                    readingError = nil
                    let plugin = pitchPlugin
                    Task {
                        do {
                            let result = try await PluginReader.read(plugin)
                            result.store(for: plugin)
                            reading = result
                        } catch {
                            readingError = error.localizedDescription
                            Diagnostics.log("plugin reader: \(error.localizedDescription)")
                        }
                        readingBusy = false
                    }
                }
                .disabled(readingBusy)
                if readingBusy { ProgressView().controlSize(.small) }
                if reading != nil {
                    Button("Forget") {
                        PluginReading.forget(for: pitchPlugin)
                        reading = nil
                    }
                }
            }
            .controlSize(.small)

            Group {
                if let error = readingError {
                    Text(error).foregroundStyle(.orange)
                } else if let reading {
                    Text(readingSummary(reading)).foregroundStyle(Theme.cue)
                } else {
                    Text("Not read yet. Until it is, minor keys are sent as their relative major — same notes — because the plug-in's scale menu layout is unknown.")
                        .foregroundStyle(Theme.upcoming)
                }
            }
            .font(.system(size: 11, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { reading = pitchPlugin.reading }
        .onChange(of: pitchPlugin) { _, plugin in
            reading = plugin.reading
            readingError = nil
        }
    }

    private func readingSummary(_ reading: PluginReading) -> String {
        var text = "Read: \(reading.rootParameter) has \(reading.rootEntryCount) entries"
        if reading.rootEntryCount > 12 { text += " (sharps and flats listed separately)" }
        if reading.canSendScale, let major = reading.majorName, let minor = reading.minorName {
            text += "; \(reading.scaleParameter ?? "Scale") has \(reading.scaleEntryCount), with “\(major)” and “\(minor)”. Keys go out as they are — D minor as D \(minor)."
        } else {
            text += "; no plain Major and Minor found in its scale menu, so minor keys still go out as their relative major."
        }
        return text
    }

    /// The mic-channel controls the Stream Deck's dials drive.
    private var mixerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MIC CHANNELS IN LOGIC").font(Theme.label).foregroundStyle(Theme.upcoming)

            Text("For the Stream Deck's dials. Each one sends a step rather than a position, so Logic moves the fader from where it is — no jumps, and nothing to catch up with. Learn each control in Logic's Controller Assignments (⌘K), aiming it at that mic's channel strip. All of these travel on MIDI channel \(MixerControl.channel + 1), so they can't collide with the key and tempo. The four plug-in slots are whatever you learn them to — MetaTune's speed or humanize, a gate threshold, anything Logic can learn.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)

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
                .controlSize(.mini)
                .disabled(!midiEnabled)
            }

            Picker("Dial steps", selection: $mixerStep) {
                ForEach(MixerControl.Step.allCases) { step in
                    Text(step.displayName).tag(step.rawValue)
                }
            }
            .font(.system(size: 11, design: .rounded))
            .frame(maxWidth: 420)
            .disabled(!midiEnabled)

            Text("In Logic's Expert view, a dial wants Mode: Relative and Format: \(MixerControl.Step(rawValue: mixerStep)?.logicFormat ?? "Sign Magnitude"); Mute wants Mode: Toggle. If a fader jumps to an end instead of nudging, that pair is what's wrong — or switch the format above.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)


        }
    }

    /// What to do once, inside the plug-in and in Logic, for the chosen one.
    private var pluginSetup: String {
        let relativeMajor = " Minor songs arrive as their relative major — D minor is sent as F major. Same seven notes, so the tuning is identical."
        let reassign = " More than one mic? Set the number of mics below and learn each plug-in with its mic picked — each gets its own MIDI channel. Logic ties an assignment to one plug-in's parameter, so switching plug-ins means assigning again."
        switch pitchPlugin {
        case .original:
            return "CC \(PitchPlugin.rootCC) carries the key and CC \(PitchPlugin.modeCC) major (0) or minor (127) — the layout this started with, for Topline Vocal Suite." + reassign
        case .logicPitchCorrection:
            return "In the plug-in, set Scale/Chord to Major once — Root is greyed out while it says Chromatic. Then assign Root to CC \(PitchPlugin.rootCC)." + relativeMajor + reassign
        case .autoTuneAccess:
            return "In the plug-in, set Scale to Major once and assign Key to CC \(PitchPlugin.rootCC). If an older assignment puts CC \(PitchPlugin.modeCC) on Scale, delete it: that switch assumes a two-entry menu, and Auto-Tune's has more." + relativeMajor + reassign
        case .wavesTuneRealTime:
            if reading?.canSendScale == true {
                return "In each mic's Waves Tune, assign Root to CC \(PitchPlugin.rootCC) and Scale to CC \(PitchPlugin.modeCC) — pick that mic under Send for Learn first, so each one learns its own channel. Use Logic's Controller Assignments (⌘K), not Waves' right-click MIDI Learn, which only hears a MIDI track routed into the plug-in."
            }
            return "Read Waves Tune first (above) so minor keys go out as minor. Then in each mic's Waves Tune assign Root to CC \(PitchPlugin.rootCC) — pick that mic under Send for Learn first. Use Logic's Controller Assignments (⌘K), not Waves' right-click MIDI Learn." + relativeMajor
        case .metaTune:
            return "MetaTune has no key control Logic can reach: its key menu only switches its twelve notes on and off. So this sends twelve controllers, CC 102 (C) to CC 113 (B), on for each note in the key. Assign each of MetaTune's note parameters with the buttons below." + reassign
        }
    }

    private var streamDeckPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stream Deck")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            Text("Keys and dials for a Stream Deck or Stream Deck+ on this Mac. After installing, find “Studio One” in the Stream Deck app's actions list and drag them onto your keys and dials — nothing needs setting up.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Install the Stream Deck plug-in") {
                    streamDeckMessage = StreamDeckInstaller.install() ?? "Handed to the Stream Deck app — confirm there if it asks."
                }
                Button("Add the Stream Deck + page") {
                    streamDeckMessage = StreamDeckInstaller.installPage()
                        ?? "Handed to the Stream Deck app. Keys: play, previous, next, key & BPM, both mic mutes, full-screen lyrics, now playing. Dials: Mic 1 and 2 level and plug-in 1; swipe the strip for key, tempo, lyric sync and volume."
                }
                .help("A ready-made two-page layout for Stream Deck +. Install the plug-in first.")
                if let port = ControlServer.shared.port {
                    Label("Listening on this Mac, port \(String(port))", systemImage: "checkmark.circle.fill")
                        .font(Theme.label).foregroundStyle(Theme.cue)
                } else {
                    Label("Control port not running", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.label).foregroundStyle(.orange)
                }
            }
            if let message = streamDeckMessage {
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("KEYS").font(Theme.label).foregroundStyle(Theme.upcoming)
                Text("Play/Pause · Next · Previous · Now Playing (album art; opens the lyrics) · Key & BPM (sends the key to Logic) · Lyrics Full Screen · Switch Source · Reload Lyrics · Logic Mic Mute · MIDI Button")
                Text("DIALS (Stream Deck+)").font(Theme.label).foregroundStyle(Theme.upcoming).padding(.top, 6)
                Text("Key — turn to transpose, press to reset, touch to send to Logic\nTempo — ±1 BPM, press to reset, tap ×2, hold ÷2\nLyric Sync — ±50 ms, press to reset, tap the strip as a line starts to sync, hold to reload\nVolume — ±2, press to mute\nSeek — ±5 s, press to play/pause, tap next, hold previous\nLyric Size — ±2 pt, press to reset\nLogic Mic Dial — a mic's level, send or plug-in control, press to mute that mic\nMIDI Dial — any controller and channel you choose")
                Text("The Logic and MIDI actions work with Studio One closed: the deck sends the MIDI itself, on the same port Logic already knows.")
                    .foregroundStyle(Theme.upcoming)
            }
            .font(.system(size: 11, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)

            Text("The plug-in talks to Studio One on 127.0.0.1 only, with a key kept in a file only your account can read, so nothing else on the network can drive playback.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
Text("Display")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 6) {
                Text("Lyrics")
                    .font(Theme.label)
                    .foregroundStyle(Theme.upcoming)
                Picker("Lyrics", selection: $lyricsStyle) {
                    ForEach(LyricsStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(lyricsStyle.detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("When LRCLIB has no timed lyrics, try NetEase Cloud Music", isOn: $netEase)
                .help("Often timed word by word. Not an official API, so it may stop working without notice.")

            Toggle("Show who's singing now and next on the lyrics screen", isOn: $singerBanner)
                .help("Guests' names come from the request line; the next song from the player's queue")

            Toggle("Show the lyrics display in the controls window", isOn: $stagePreview)
                .help("A live thumbnail of what the room is seeing, in place of the album art")

            Toggle("Show key and BPM in the menu bar", isOn: $menuBarReadout)
                .help("Readable without bringing a window forward")

            Toggle("Keep windows above other apps", isOn: $alwaysOnTop)
                .font(.system(size: 12, design: .rounded))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Frame rate")
                        .font(Theme.label)
                        .foregroundStyle(Theme.upcoming)
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
                    .foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Diagnostics")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Copy log") {
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
                    .foregroundStyle(logNotice == nil ? Theme.upcoming : Theme.cue)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    /// Hidden unless asked for. These are readable secrets sitting in a pane
    /// that gets opened while screen-sharing, and a masked field you can reveal
    /// is friendlier than one you can never check what you pasted into.
    @ViewBuilder
    private func secret(_ text: Binding<String>) -> some View {
        if revealKeys {
            TextField("", text: text)
        } else {
            SecureField("", text: text)
        }
    }

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.label)
                .foregroundStyle(Theme.upcoming)
            content()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    /// Writes only what changed. Rewriting an unchanged keychain item is
    /// not free: it can bring back the keychain prompt for that item.
    private func save() {
        if clientID != stored.clientID || clientSecret != stored.clientSecret {
            Credentials.write(clientID.trimmingCharacters(in: .whitespaces), for: .clientID)
            Credentials.write(clientSecret.trimmingCharacters(in: .whitespaces), for: .clientSecret)
            Task { await SpotifyAPI.shared.resetToken() }
        }
        if songBPMKey != stored.songBPM {
            Credentials.write(songBPMKey.trimmingCharacters(in: .whitespaces), for: .songBPM)
            // Drop cached lookups so a new key takes effect on the current track.
            Task { await AnalysisProvider.shared.invalidate() }
        }
        dismiss()
    }
}
