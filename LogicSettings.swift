import SwiftUI

/// Settings › Logic: the MIDI port, the tuners and how each control is learned,
/// bypassing with no key, and the tempo — shown once MIDI is on. Checking what
/// was sent, and the backups, are in Rig check.
struct LogicSettings: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var bridge = MIDIBridge.shared
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @AppStorage(MIDIBridge.clockKey) private var midiClock = false
    @AppStorage(MIDIBridge.catchUpKey) private var catchUp = true
    @AppStorage(MIDIBridge.mackieSafeKey) private var mackieSafe = false
    @AppStorage(MIDIBridge.bypassKey) private var bypassWithoutKey = true
    @AppStorage(MIDIBridge.bypassInvertedKey) private var bypassInverted = false
    @AppStorage(PitchPlugin.defaultsKey) private var pitchPlugin: PitchPlugin = .original
    @AppStorage(PitchPlugin.invertNotesKey) private var invertNotes = false
    @AppStorage(PitchPlugin.tunerCountKey) private var tunerCount = 1
    @AppStorage("settingsInfo.tempo.learnTip") private var tempoTipOpen = false
    /// Which mic's channel the Send for Learn buttons use.
    @State private var learnTuner = 0
    @State private var reading: PluginReading?
    @State private var readingBusy = false
    @State private var readingError: String?
    @State private var swallowers: [LogicAssignments.Swallower] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Send to Logic")

            SettingsSection("") {
                Toggle("Send key and tempo as MIDI", isOn: $midiEnabled)
                    .font(.system(size: 12, design: .rounded))
                    .info("Publishes a MIDI source named “Studio One”. For the tuners: in Logic, open Controller Assignments (⌥⇧K, or Logic Pro › Control Surfaces), turn on Learn Mode, touch a plug-in parameter, then press the matching Send for Learn button. Pause the music and don't walk the switches while Learn Mode is on: a song change sends its whole key at once, and Logic learns all of it as one control that then swallows that key. Tempo is set up differently — see Tempo below.")
                if midiEnabled {
                    Toggle("Keep clear of Mackie Control", isOn: $mackieSafe)
                        .font(.system(size: 12, design: .rounded))
                        .info(mackieSafe
                              ? "Key and scale use CC \(PitchPlugin.rootCC) and \(PitchPlugin.modeCC), which a Mackie Control ignores. Assignments learned on the old numbers need learning again."
                              : "Key and scale use CC \(PitchPlugin.rootCC) and \(PitchPlugin.modeCC). On channel 1 a Mackie Control reads CC 16–23 as its knobs; if one is set up in Logic, turn this on (and learn those again). MetaTune's switches and the tempo are clear either way.")
                } else {
                    Text("Turn this on to send each song's key and tempo to the tuners in Logic. The tuner, no-key and tempo settings appear here once it's on.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !swallowers.isEmpty {
                    SwallowerWarnings(swallowers: swallowers)
                }
            }

            if midiEnabled {
                tuners
                noKey
                tempo
                Text("Sending a test key, and the backups of what Logic has learned, are in Rig check.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .task { swallowers = await Task.detached(priority: .utility) { LogicAssignments.swallowers() }.value }
    }

    private var tuners: some View {
        SettingsSection("Tuners") {
            LabelledRow("Pitch plug-in:") {
                Picker("Pitch plug-in", selection: $pitchPlugin) {
                    ForEach(PitchPlugin.listed(keeping: pitchPlugin)) { plugin in
                        Text(plugin.displayName).tag(plugin)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .info(pluginSetup)

            if pitchPlugin.isReadable { readRow }

            LabelledRow("Mics with a tuner:") {
                Picker("Mics with a tuner", selection: $tunerCount) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                Text(tunerCount > 1 ? "Mic 1 on MIDI channel 1, Mic 2 on channel 2…" : "")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
            }

            // Learn Mode needs a message while it listens, so these send on
            // demand. One line where it fits, else two.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        learnKeyButtons
                        learnOtherButtons
                    }
                    .controlSize(.small)
                    tempoTipToggle
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { learnKeyButtons }
                        .controlSize(.small)
                    HStack(spacing: 8) {
                        HStack(spacing: 8) { learnOtherButtons }
                            .controlSize(.small)
                        tempoTipToggle
                    }
                }
            }
            .onChange(of: tunerCount) { _, count in learnTuner = min(learnTuner, count - 1) }
            if tempoTipOpen {
                tempoLearnTip
            }

            if pitchPlugin.scheme == .noteSwitches {
                // One per switch: each needs its own assignment.
                HStack(spacing: 4) {
                    ForEach(0..<12, id: \.self) { pitchClass in
                        Button(PitchPlugin.noteNames[pitchClass]) {
                            MIDIBridge.shared.sendForLearn(model.publishedAnalysis, control: .note(pitchClass),
                                                           tuner: learnTuner)
                        }
                        .help("CC \(PitchPlugin.noteCC(pitchClass))")
                    }
                }
                .controlSize(.small)
                .info("These are for learning only — one button per MetaTune switch, once per mic. You never pick notes per song: when a song starts, Studio One works out its scale and sets all twelve switches itself (D major: D E F♯ G A B C♯ on, the rest off). MetaTune has no single key control a DAW can reach — Slate records even its own key menu as these twelve switches.")

                StatusLine(metaTuneNow)

                HStack(spacing: 10) {
                    Button("Walk the Switches") {
                        MIDIBridge.shared.walkNoteSwitches(tuner: learnTuner, restoring: model.publishedAnalysis)
                    }
                    .help("Lights each note alone, C to B, on the mic picked above — watch MetaTune: each key should light in turn")
                    Toggle("Notes arrive inverted", isOn: $invertNotes)
                        .font(.system(size: 12, design: .rounded))
                        .help("Turn on if a test lights exactly the five notes that should be off")
                }
                .controlSize(.small)
                .info("Walk the Switches lights C alone, then C♯, and so on to B, on the mic picked above, then puts the song's key back. A key that lights out of turn, or not at all, needs learning again.")
            }

            Toggle("Sweep before each key change", isOn: $catchUp)
                .font(.system(size: 12, design: .rounded))
                .info("Logic's Pickup mode ignores a jump straight to a new value; a quick sweep through every value gets past it, as the Learn button does. The plug-in flicks through keys for about a third of a second at each song change.")
        }
    }

    private var noKey: some View {
        SettingsSection("No key", info: bypassSteps) {
            Toggle("Bypass the tuners when a song has no key", isOn: $bypassWithoutKey)
                .font(.system(size: 12, design: .rounded))
                .onChange(of: bypassWithoutKey) { _, on in
                    if !on { MIDIBridge.shared.bypassTurnedOff() }
                }
            if bypassWithoutKey {
                HStack(spacing: 10) {
                    Text("Test:").font(Theme.label).foregroundStyle(Theme.secondary)
                    Button("Bypass") { MIDIBridge.shared.sendBypass(true) }
                    Button("Back On") { MIDIBridge.shared.sendBypass(false) }
                    Toggle("Arrives inverted", isOn: $bypassInverted)
                        .font(.system(size: 12, design: .rounded))
                        .help("Turn on if the tuners go off when a song has a key, and on when it hasn't")
                }
                .controlSize(.small)
                StatusLine(bypassNow)
            }
        }
    }

    private var tempo: some View {
        SettingsSection("Tempo", info: "The tempo goes out as pitch bend on MIDI channel \(MIDIBridge.tempoChannel + 1): one message carrying the whole value, which Logic learns at full resolution. Logic keeps a tempo from a controller to the whole BPM, so a song at 86.5 arrives as 87. To set it up, press Show tip beside Tempo under Send for Learn. Set up before? The old row — CC 22 or HRCC 22 → Tempo, from Studio One — no longer receives anything and can be deleted; a tempo row for another controller, such as the M-BRIO, can stay.") {
            Button("Send This Song's Tempo") { MIDIBridge.shared.sendTempoNow(model.publishedAnalysis) }
                .controlSize(.small)
            if let check = tempoCheck {
                // Not folded: comparing it with Logic is the test.
                StatusLine(check)
            }
            Toggle("Also send MIDI beat clock", isOn: $midiClock)
                .font(.system(size: 12, design: .rounded))
                .info("Only followed when Logic is set to external sync — which slaves its transport as well as its tempo. Leave off if you're tracking into an arranged session.")
                .padding(.top, 4)
        }
    }

    /// Ask the installed plug-in how its key and scale menus are laid out.
    private var readRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button(readingBusy ? "Reading…" : "Read \(pitchPlugin.displayName) on This Mac") {
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
                        .foregroundStyle(Theme.secondary)
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

    // MARK: - Send for Learn

    /// Send for Learn's label, the mic it's for, and the key's own controls.
    @ViewBuilder private var learnKeyButtons: some View {
        Text("Send for Learn:")
            .font(Theme.label)
            .foregroundStyle(Theme.secondary)
        if tunerCount > 1 {
            Picker("", selection: $learnTuner) {
                ForEach(0..<tunerCount, id: \.self) { Text("Mic \($0 + 1)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 76)
        }
        if pitchPlugin.scheme != .noteSwitches {
            Button(pitchPlugin == .autoTuneAccess ? "Key" : "Root") {
                MIDIBridge.shared.sendForLearn(model.publishedAnalysis, control: .key, tuner: learnTuner)
            }
        }
        if pitchPlugin.scheme == .rootAndMode || reading?.canSendScale == true {
            Button(pitchPlugin.scheme == .rootAndMode && reading == nil ? "Major/Minor" : "Scale") {
                MIDIBridge.shared.sendForLearn(model.publishedAnalysis, control: .mode, tuner: learnTuner)
            }
        }
    }

    /// The rest of Send for Learn: the no-key bypass and the tempo.
    @ViewBuilder private var learnOtherButtons: some View {
        if bypassWithoutKey {
            Button("Bypass") {
                MIDIBridge.shared.sendForLearn(model.publishedAnalysis, control: .bypass, tuner: learnTuner)
            }
            .help("Sends CC \(MIDIBridge.bypassCC) for Logic to learn — click the Bypass button in the tuner's plug-in window first. See No key below")
        }
        Button("Tempo") { MIDIBridge.shared.learnTempo(model.publishedAnalysis) }
            .help("Sends pitch bend on channel \(MIDIBridge.tempoChannel + 1) for Logic to learn — Show tip, beside it, has the steps")
    }

    /// Kept out of the disabled row, to be readable with MIDI off.
    private var tempoTipToggle: some View {
        InfoToggle(open: $tempoTipOpen, noun: "tip", icon: "lightbulb",
                   help: "How to set up the tempo in Logic")
    }

    // MARK: - Tempo

    /// What Logic should show for the song playing.
    private var tempoCheck: String? {
        guard let tempo = model.publishedAnalysis?.tempo, tempo > 0 else { return nil }
        return "This song: Logic should show \(MIDIBridge.logicTempo(for: tempo)) BPM."
    }

    /// Show tip, beside the Tempo button: setting the tempo up in Logic.
    /// Learn Mode can't aim at the tempo — clicking it in Logic doesn't count
    /// as touching a parameter — so the learned row is pointed at it after.
    private var tempoLearnTip: some View {
        let check = model.publishedAnalysis?.tempo.map {
            " Logic should show **\(MIDIBridge.logicTempo(for: $0))\u{00A0}BPM**."
        } ?? ""
        return TipSteps(lead: "Setting up the tempo in Logic, once:", steps: [
            .init(text: "Press **⌥⇧K** for Controller Assignments and click **Learn Mode**."),
            .init(text: "Press **Tempo** here. Logic adds a row called **Pitchbend**, aimed at whatever you last touched in Logic."),
            .init(text: "Click **Learn Mode** again to stop."),
            .init(text: "Click **Expert View**. With the Pitchbend row selected, set **Class** to **Global** and **Parameter** to **Tempo**. Leave the rest: Value Change already reads `EF Lo7 Hi7`, the whole value, and Input is Studio One."),
            .init(text: "Press **Send This Song's Tempo**." + check),
        ])
    }

    // MARK: - What the plug-ins should show

    /// What the tuners should be doing, from what Studio One last told them.
    private var bypassNow: String {
        let tuners = tunerCount > 1 ? "every mic's tuner" : "the tuner"
        guard bridge.tunersBypassed else { return "Right now \(tuners) should be on." }
        let hint = model.track != nil && model.publishedAnalysis?.key == nil
            ? " This song has no key — type one in and \(tunerCount > 1 ? "they come" : "it comes") back on."
            : ""
        return "Right now \(tuners) should be bypassed.\(hint)"
    }

    private var bypassSteps: String {
        """
        When no source finds a key for a song, Studio One bypasses the tuners, so nobody is pulled toward the last song's key. They come back on when a key arrives — typed in, from the Stream Deck's Key dial, or the next song's own — just after it has landed. It's CC \(MIDIBridge.bypassCC) on each mic's channel: 127 bypasses, 0 brings back, sent only when that changes.

        To learn it, once per mic: in Logic open Controller Assignments (⌥⇧K) and turn on Learn Mode, click the Bypass button at the left of the tuner's plug-in window header (or, in MetaTune, its own Bypass control), pick that mic under Send for Learn and press Bypass, then turn Learn Mode off. If the tuner stays bypassed afterwards, press Back on.

        If the tuners go off when a song has a key and on when it hasn't: in Controller Assignments' Expert view, check that assignment's Mode is Direct, not Toggle — and if it is, turn on Arrives inverted.
        """
    }

    /// What MetaTune should be showing for the song that's playing, so a
    /// switched-off note reads as the key being applied, not a fault.
    private var metaTuneNow: String {
        guard let key = model.publishedAnalysis?.key, let coded = MIDIBridge.encode(key: key) else {
            return "Nothing with a known key is playing. When a song is, its notes are set on every mic by themselves."
        }
        let lists = PitchPlugin.noteLists(root: coded.root, minor: coded.minor)
        return "Playing now: \(PitchPlugin.noteNames[coded.root]) \(coded.minor ? "minor" : "major"). MetaTune should show \(lists.on.joined(separator: " ")) on and \(lists.off.joined(separator: " ")) off — those five aren't in this song's key, so they're switched off on purpose."
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
                return "In each mic's Waves Tune, assign Root to CC \(PitchPlugin.rootCC) and Scale to CC \(PitchPlugin.modeCC) — pick that mic under Send for Learn first, so each one learns its own channel. Use Logic's Controller Assignments (⌥⇧K), not Waves' right-click MIDI Learn, which only hears a MIDI track routed into the plug-in."
            }
            return "Read Waves Tune first (above) so minor keys go out as minor. Then in each mic's Waves Tune assign Root to CC \(PitchPlugin.rootCC) — pick that mic under Send for Learn first. Use Logic's Controller Assignments (⌥⇧K), not Waves' right-click MIDI Learn." + relativeMajor
        case .metaTune:
            return "MetaTune has no key control Logic can reach: its key menu only switches its twelve notes on and off. So this sends twelve controllers, CC 102 (C) to CC 113 (B), on for each note in the key. To learn one: in Logic's Controller Assignments (⌥⇧K) turn on Learn Mode, touch that note in MetaTune, then press the matching note button below. If Logic doesn't pick up the note you click, switch MetaTune's window to Logic's generic view (the View menu at the top of the plug-in window › Controls) and touch the note there — some plug-in windows don't tell Logic which control was touched." + reassign
        }
    }
}

/// Rig check's test of the key path: send a key and see whether the tuners
/// follow, with what actually went out — to tell "not sent" from "not heard".
/// Moved here from Logic, which is for setting up; this is for checking.
struct LogicCheckSection: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var bridge = MIDIBridge.shared
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @AppStorage(PitchPlugin.defaultsKey) private var pitchPlugin: PitchPlugin = .original
    @AppStorage(PitchPlugin.tunerCountKey) private var tunerCount = 1
    @State private var testRoot = 2
    @State private var testMinor = true
    let swallowers: [LogicAssignments.Swallower]

    var body: some View {
        SettingsSection("Send a test key") {
            if !swallowers.isEmpty {
                SwallowerWarnings(swallowers: swallowers)
            }
            if midiEnabled {
                HStack(spacing: 8) {
                    Text("Key:")
                        .font(Theme.label)
                        .foregroundStyle(Theme.secondary)
                    Picker("Note", selection: $testRoot) {
                        ForEach(0..<12, id: \.self) { Text(PitchPlugin.noteNames[$0]).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 64)
                    Picker("Scale", selection: $testMinor) {
                        Text("major").tag(false)
                        Text("minor").tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 84)
                    Button("Send") { MIDIBridge.shared.sendTest(root: testRoot, minor: testMinor) }
                    Button("Send This Song's Key") { model.publishToLogic() }
                        .help("Sends what's playing now, without waiting for the next track")
                }
                .controlSize(.small)

                StatusLine("\(tunerCount > 1 ? "Every mic's plug-in" : "The plug-in") should read: \(pitchPlugin.expectedReading(root: testRoot, minor: testMinor, reading: pitchPlugin.reading))")

                Text("Last sent: \(bridge.lastSent)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Turn on “Send key and tempo as MIDI” in Settings › Logic first.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}
