import CoreMIDI
import Foundation

/// Publishes the current track's key and tempo as MIDI on a virtual source
/// named "Spot-a-oke".
///
/// The port keeps the app's old name on purpose. Logic files controller
/// assignments under the port they were learned on, so renaming this endpoint
/// would orphan every assignment already made against it. The name is an
/// identifier here, not a label.
///
/// Plugins have no external API, and the AU/VST host protocol has no concept of
/// musical key — but any automatable plugin parameter can be MIDI-learned in
/// Logic's Controller Assignments. A control change per track change is therefore
/// the one channel that reaches something like Topline Vocal Suite's key setting.
@MainActor
final class MIDIBridge: ObservableObject {

    /// What went out last, in words — shown in Settings and written to the log,
    /// so "nothing happens in Logic" can be split into "nothing was sent" and
    /// "it was sent and went nowhere". Before this, a track with no key was
    /// skipped silently and the two looked identical.
    @Published private(set) var lastSent = "Nothing sent yet this session."

    static let shared = MIDIBridge()

    /// Learn these in Logic: Controller Assignments → Learn Mode, touch the
    /// plugin parameter, then let the app send on the next track change. What
    /// carries the key depends on the plug-in — see `PitchPlugin`.
    static var tempoCC: UInt8 { mackieSafe ? 87 : 22 }    // see logicTempo* below

    /// Moves key, scale and tempo off CC 20–22 on channel 1.
    ///
    /// A Mackie Control reads CC 16–23 on channel 1 as its eight V-Pots,
    /// turned relative — the same shape as a key change. With a Mackie Control
    /// surface set up in Logic (another Stream Deck plug-in installs one) and
    /// listening broadly, a song change here could turn V-Pots on the mixer.
    /// CC 85, 86, 87 and 119 mean nothing to it. Off unless chosen, because
    /// switching means learning those assignments again.
    nonisolated static let mackieSafeKey = "midiMackieSafe"
    nonisolated static var mackieSafe: Bool { UserDefaults.standard.bool(forKey: mackieSafeKey) }

    /// Logic's Tempo parameter spans 5–990 BPM, and a controller assignment maps
    /// the whole CC range onto it. The Value Minimum/Maximum fields that would
    /// narrow that are greyed out for Global > Tempo, so the encoding has to
    /// match Logic's range rather than a nominal musical one — otherwise 130 BPM
    /// arrives as 501.
    static let logicTempoMin = 5.0
    static let logicTempoMax = 990.0

    /// Fine half of the 14-bit tempo pair. MIDI convention puts the LSB 32
    /// controllers above the MSB, so CC 22 pairs with CC 54.
    static var tempoFineCC: UInt8 { mackieSafe ? 119 : 54 }

    /// Tempo as a 14-bit value: 16,384 steps across Logic's 5–990 BPM range is
    /// about 0.06 BPM, against 7.76 BPM for a plain 7-bit CC.
    static func tempo14Bit(for bpm: Double) -> (msb: UInt8, lsb: UInt8) {
        let span = logicTempoMax - logicTempoMin
        let scaled = ((bpm - logicTempoMin) / span * 16383).rounded()
        let value = Int(min(16383, max(0, scaled)))
        return (UInt8(value >> 7), UInt8(value & 0x7F))
    }

    /// Fixed identity for the virtual endpoint ("SPOK" as ASCII).
    ///
    /// CoreMIDI assigns a random unique ID to a virtual source unless told
    /// otherwise, and hosts key their controller assignments off that ID — so
    /// every rebuild looks like a different MIDI interface and Logic drops the
    /// mappings. Pinning it keeps the device identical across rebuilds.
    private static let endpointID: Int32 = 0x53504F4B

    static let enabledKey = "midiBridgeEnabled"
    static let catchUpKey = "midiKeyCatchUp"

    /// On unless turned off. See `sendKey`.
    static var catchesUp: Bool {
        UserDefaults.standard.object(forKey: catchUpKey) as? Bool ?? true
    }

    /// Bumped on every key send, so a sweep still in flight from the previous
    /// song can't land after the new one and leave the wrong key behind.
    private var keyGeneration = 0
    static let clockKey = "midiClockEnabled"

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var ready = false
    private var clockTimer: DispatchSourceTimer?
    private var identityTimer: Timer?

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private var clockEnabled: Bool { UserDefaults.standard.bool(forKey: Self.clockKey) }

    func start() {
        guard !ready else { return }
        let clientStatus = MIDIClientCreate("Spot-a-oke" as CFString, nil, nil, &client)
        let sourceStatus = clientStatus == noErr
            ? MIDISourceCreate(client, "Spot-a-oke" as CFString, &source) : clientStatus
        guard sourceStatus == noErr else {
            // Seen when the previous instance is still letting go of the port.
            // Silence here looked like "MIDI does nothing" with no way to tell
            // why, so it says so and tries again rather than giving up.
            Diagnostics.log("midi: port not created (\(sourceStatus)) — trying again")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
            return
        }

        // Claim the stable identity, and keep trying if something else holds
        // it. That something is the Stream Deck plug-in, which takes this same
        // identity while this app is shut so its own messages reach the
        // assignments Logic already knows, and lets go when this app appears.
        // Without the retry the app would launch into a random identity — one
        // Logic has never been taught — and every assignment would go deaf.
        claimIdentity()
        MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, "Spot-a-oke" as CFString)
        MIDIObjectSetStringProperty(source, kMIDIPropertyModel, "Spot-a-oke" as CFString)

        ready = true
        Self.liveSource = source
    }

    // MARK: - Fast lane

    /// The port, readable from any thread, for the Stream Deck's dial ticks.
    /// An endpoint is a plain number and is only ever set once, so reading it
    /// off the main thread is safe; `MIDIReceived` may be called from anywhere.
    nonisolated(unsafe) private static var liveSource = MIDIEndpointRef()
    nonisolated(unsafe) private static var pendingLabel: String?
    nonisolated private static let labelLock = NSLock()

    /// Puts a message on the port at once, from whatever thread it arrived on.
    ///
    /// A dial being spun sends thirty or more of these a second. Routed through
    /// the main thread they queued behind whatever it was drawing — the lyrics,
    /// usually — which is what made a fader lag the hand. The "Last sent" line
    /// is still updated, with the latest message, at most ten times a second.
    nonisolated static func sendNow(_ bytes: [UInt8], label: String) {
        let source = liveSource
        guard source != 0 else { return }
        transmit(bytes, from: source)
        let text = "\(label) → CC \(bytes[1]) = \(bytes[2]) on channel \((bytes[0] & 0x0F) + 1)."
        labelLock.lock()
        let schedule = pendingLabel == nil
        pendingLabel = text
        labelLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            labelLock.lock()
            let latest = pendingLabel
            pendingLabel = nil
            labelLock.unlock()
            if let latest { MainActor.assumeIsolated { shared.note(latest) } }
        }
    }

    /// Called on every track change once key and tempo are known.
    /// Claims the identity, and keeps watching until it has it.
    ///
    /// A fixed number of tries was not enough: whoever holds the identity
    /// decides how long this takes, and a run of tries that ends first leaves
    /// the app on a random identity for the rest of the session — every Logic
    /// assignment deaf, with nothing to say so. Checking every few seconds
    /// costs one property read and cannot be outlasted.
    private func claimIdentity() {
        guard identityTimer == nil else { return }
        if tryClaimIdentity() { return }
        Diagnostics.log("midi: port identity held elsewhere — waiting for it")
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                if self.tryClaimIdentity() {
                    timer.invalidate()
                    self.identityTimer = nil
                }
            }
        }
        identityTimer = timer
    }

    private func tryClaimIdentity() -> Bool {
        var current: Int32 = 0
        MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &current)
        if current == Self.endpointID { return true }
        guard MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, Self.endpointID) == noErr else {
            return false
        }
        Diagnostics.log("midi: port identity claimed")
        return true
    }

    func publish(_ analysis: TrackAnalysis?) {
        guard ready, isEnabled else { return }

        if let key = analysis?.key, let coded = Self.encode(key: key) {
            sendKey(root: coded.root, minor: coded.minor, reason: "song")
        } else {
            note("No key for this song, so no key was sent" + (analysis?.key.map { " (couldn't read “\($0)”)" } ?? "") + ".")
        }

        if let tempo = analysis?.tempo, tempo > 0 {
            // MSB first, then LSB — the order hosts expect for a 14-bit pair.
            let parts = Self.tempo14Bit(for: tempo)
            send(cc: Self.tempoCC, value: parts.msb)
            send(cc: Self.tempoFineCC, value: parts.lsb)
        }

        setClock(bpm: analysis?.tempo)
    }

    /// The key, shaped for whichever plug-in is chosen, sent once per tuner on
    /// that tuner's channel.
    private func sendKey(root: Int, minor: Bool, reason: String) {
        let plugin = PitchPlugin.current
        let messages = plugin.messages(root: root, minor: minor,
                                       invertNotes: PitchPlugin.invertsNotes,
                                       reading: plugin.reading)
        // Logic's Pickup mode ignores a controller until it "reaches" the
        // parameter's current value. A single jump to the new key never does,
        // so it was dropped — while the Learn button's sweep, which passes
        // through every value, got through every time. That difference is the
        // whole symptom as reported from the rig. So each key goes out the
        // way Learn sends it: a run from 0 to 127, then the value itself.
        keyGeneration += 1
        let generation = keyGeneration
        let endpoint = source
        let path: [UInt8] = Self.catchesUp ? [0, 21, 42, 64, 85, 106, 127] : []
        for (step, value) in (path.map { Optional($0) } + [nil]).enumerated() {
            let transmit: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.keyGeneration == generation else { return }
                for channel in 0..<PitchPlugin.tunerCount {
                    for message in messages {
                        Self.transmit([0xB0 | UInt8(channel), message.cc, min(127, value ?? message.value)],
                                      from: endpoint)
                    }
                }
            }
            if step == 0 { transmit() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.04, execute: transmit)
            }
        }
        let values = messages.map { "CC \($0.cc) = \($0.value)" }.joined(separator: ", ")
        let mics = PitchPlugin.tunerCount == 1
            ? "channel 1"
            : "channels 1–\(PitchPlugin.tunerCount), one per mic"
        note("\(PitchPlugin.noteNames[root]) \(minor ? "minor" : "major") (\(reason)) → \(values) on \(mics).")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    private func note(_ text: String) {
        lastSent = "\(Self.clock.string(from: Date()))  \(text)"
        Diagnostics.log("midi: \(text)")
    }

    // MARK: - Mixer

    /// One step of a mic-channel dial. See `MixerControl`.
    func sendMixer(_ control: MixerControl, ticks: Int) {
        // Not gated on `isEnabled`: that switch is about publishing key and
        // tempo by itself. This is someone turning a dial.
        guard ready, control.kind == .dial, ticks != 0 else { return }
        let value = MixerControl.value(forTicks: ticks)
        send(cc: control.cc, value: value, channel: MixerControl.channel)
        note("\(control.name) \(ticks > 0 ? "up" : "down") \(abs(ticks)) → CC \(control.cc) = \(value) on channel \(MixerControl.channel + 1).")
    }

    /// A button: 127, the value Logic's Toggle mode acts on.
    func sendMixerToggle(_ control: MixerControl) {
        guard ready else { return }
        send(cc: control.cc, value: 127, channel: MixerControl.channel)
        note("\(control.name) → CC \(control.cc) = 127 on channel \(MixerControl.channel + 1).")
    }

    /// Any controller message, for the Stream Deck's freely-assignable actions.
    /// Kept on this one port so an assignment learned in Logic answers whether
    /// the message came from here or from the deck sending it itself.
    func sendRaw(cc: UInt8, value: UInt8, channel: UInt8, label: String?) {
        guard ready else { return }
        send(cc: cc, value: value, channel: channel)
        note("\(label ?? "MIDI") → CC \(cc) = \(value) on channel \(channel + 1).")
    }

    /// Something for Logic's Learn Mode to catch. A dial has to be seen moving
    /// both ways or Logic can't tell it is an encoder; a button has to be seen
    /// pressed and released.
    func sendMixerForLearn(_ control: MixerControl) {
        guard ready else { return }
        let endpoint = source
        let steps: [UInt8] = control.kind == .dial
            ? (0..<6).map { _ in MixerControl.value(forTicks: 1) }
                + (0..<2).map { _ in MixerControl.value(forTicks: -1) }
            : [127, 0, 127, 0]
        for (index, value) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.06) {
                Self.transmit([0xB0 | MixerControl.channel, control.cc, value], from: endpoint)
            }
        }
        note("Learn: \(control.name) on CC \(control.cc), channel \(MixerControl.channel + 1).")
    }

    // MARK: - Song controls

    private var songGeneration = 0

    /// A song's settings, on its start. See `SongControl`. Swept then landed,
    /// like the key and for the same reason — Logic's Pickup mode ignores a
    /// jump — unless `sweep` is false, as for a slider being dragged, which
    /// passes through the values on its own.
    func sendSongControls(_ messages: [(cc: UInt8, value: UInt8)], sweep: Bool, label: String) {
        guard ready, isEnabled, !messages.isEmpty else { return }
        songGeneration += 1
        let generation = songGeneration
        let endpoint = source
        let path: [UInt8] = sweep && Self.catchesUp ? [0, 21, 42, 64, 85, 106, 127] : []
        for (step, value) in (path.map { Optional($0) } + [nil]).enumerated() {
            let transmit: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.songGeneration == generation else { return }
                for message in messages {
                    Self.transmit([0xB0 | SongControl.channel, message.cc, value ?? message.value],
                                  from: endpoint)
                }
            }
            if step == 0 { transmit() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.04, execute: transmit)
            }
        }
        let values = messages.map { "CC \($0.cc) = \($0.value)" }.joined(separator: ", ")
        note("\(label) → \(values) on channel \(SongControl.channel + 1).")
    }

    /// Something for Learn Mode to bind to: a sweep, then the value in use.
    func sendSongControlForLearn(slot: Int, settle: Int) {
        guard ready else { return }
        let endpoint = source
        let cc = SongControl.cc(slot)
        for (index, value) in ([0, 21, 42, 64, 85, 106, 127, UInt8(min(127, max(0, settle)))]).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.04) {
                Self.transmit([0xB0 | SongControl.channel, cc, value], from: endpoint)
            }
        }
        note("Learn: song control \(slot + 1) on CC \(cc), channel \(SongControl.channel + 1).")
    }

    /// Sends a chosen key straight away, so the plug-in can be checked by eye
    /// without waiting for a song in that key to come up.
    func sendTest(root: Int, minor: Bool) {
        guard ready, isEnabled else { return }
        sendKey(root: root, minor: minor, reason: "test")
    }

    /// Sends the current values on demand, so a DAW sitting in MIDI-learn mode
    /// has something to bind to without waiting for the next track change.
    ///
    /// Falls back to mid-range values when nothing is playing — you should be
    /// able to set the mapping up before starting a song.
    /// `tuner` picks the channel, so each mic's plug-in is learned against its
    /// own. Tempo always goes on the first.
    func sendForLearn(_ analysis: TrackAnalysis?, control: LearnTarget, tuner: Int = 0) {
        guard ready, isEnabled else { return }

        let plugin = PitchPlugin.current
        let coded = analysis?.key.flatMap(Self.encode(key:))
        let keyMessages = coded.map {
            plugin.messages(root: $0.root, minor: $0.minor,
                            invertNotes: PitchPlugin.invertsNotes, reading: plugin.reading)
        } ?? []
        let channel = control == .tempo ? UInt8(0) : UInt8(min(max(tuner, 0), 15))

        let cc: UInt8
        let settled: UInt8

        switch control {
        case .key:
            cc = PitchPlugin.rootCC
            settled = keyMessages.first { $0.cc == cc }?.value ?? 64
        case .mode:
            cc = PitchPlugin.modeCC
            settled = keyMessages.first { $0.cc == cc }?.value ?? 127
        case .note(let pitchClass):
            cc = PitchPlugin.noteCC(pitchClass)
            settled = keyMessages.first { $0.cc == cc }?.value ?? 127
        case .tempo:
            cc = Self.tempoCC
            settled = analysis?.tempo.map { Self.tempo14Bit(for: $0).msb } ?? 64
        }

        // A host in learn mode is waiting for a control to *move*. One lone
        // message often isn't enough to recognise — a hardware knob emits a
        // stream. Sweep the range, then settle on the real value.
        let sweep: [UInt8] = [0, 21, 42, 64, 85, 106, 127, settled]
        let endpoint = source

        let fine: UInt8? = control == .tempo ? Self.tempoFineCC : nil
        let settledFine = analysis?.tempo.map { Self.tempo14Bit(for: $0).lsb } ?? 0

        for (step, value) in sweep.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.04) {
                Self.transmit([0xB0 | channel, cc, min(127, value)], from: endpoint)
                // Send the fine half too, so a host learning tempo sees the pair.
                if let fine {
                    let lsb = value == settled ? settledFine : value
                    Self.transmit([0xB0 | channel, fine, min(127, lsb)], from: endpoint)
                }
            }
        }
    }

    enum LearnTarget: Equatable {
        case key, mode, tempo
        /// One of MetaTune's twelve note switches, 0 = C.
        case note(Int)
    }

    /// MIDI beat clock, off unless explicitly enabled — Logic only follows it in
    /// external sync, which slaves its transport as well as its tempo.
    func setClock(bpm: Double?) {
        clockTimer?.cancel()
        clockTimer = nil

        guard ready, isEnabled, clockEnabled, let bpm, bpm > 20, bpm < 400 else { return }

        let endpoint = source
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInteractive))
        // 24 pulses per quarter note is the MIDI clock standard.
        timer.schedule(deadline: .now(), repeating: 60.0 / (bpm * 24.0),
                       leeway: .nanoseconds(100_000))
        timer.setEventHandler { Self.transmit([0xF8], from: endpoint) }
        timer.resume()
        clockTimer = timer
    }

    func stopClock() {
        clockTimer?.cancel()
        clockTimer = nil
    }

    // MARK: - Encoding

    /// "F♯m" → (root 6, minor). Handles both ♯/♭ and #/b spellings.
    /// The inverse of `encode`, for nudging a key by semitones. Sharps rather
    /// than flats throughout, so a nudge never flips notation mid-song.
    static func decode(root: Int, minor: Bool) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[((root % 12) + 12) % 12] + (minor ? "m" : "")
    }

    static func encode(key: String) -> (root: Int, minor: Bool)? {
        let text = key.trimmingCharacters(in: .whitespaces)
        let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5,
                                          "G": 7, "A": 9, "B": 11]
        guard let head = text.first,
              var index = naturals[Character(head.uppercased())] else { return nil }

        var rest = text.dropFirst()
        if rest.hasPrefix("♯") || rest.hasPrefix("#") { index += 1; rest = rest.dropFirst() }
        else if rest.hasPrefix("♭") || rest.hasPrefix("b") { index -= 1; rest = rest.dropFirst() }

        // The quality is whatever follows the note. This used to test only
        // for a trailing "m", so "A minor", "E♭ minor" and "G min" all read
        // as major — the wrong scale sent to the tuners, silently. Now "m",
        // "min", "minor" and "m7" are minor; "maj", "major" and a capital
        // "M" (the classical spelling of major) are not.
        let quality = rest.trimmingCharacters(in: .whitespaces)
        let lowered = quality.lowercased()
        let capitalMajor = quality.hasPrefix("M") && !lowered.hasPrefix("mi")
        let minor = lowered.hasPrefix("m") && !lowered.hasPrefix("maj") && !capitalMajor

        return ((index % 12 + 12) % 12, minor)
    }

    // MARK: - Transmission

    private func send(cc: UInt8, value: UInt8, channel: UInt8 = 0) {
        Self.transmit([0xB0 | (channel & 0x0F), cc, min(127, value)], from: source)
    }

    /// nonisolated so the clock timer can transmit from its own queue;
    /// MIDIReceived is safe to call from any thread.
    nonisolated private static func transmit(_ bytes: [UInt8], from endpoint: MIDIEndpointRef) {
        var payload = bytes
        var list = MIDIPacketList()

        // The pointer has to stay valid for the whole build-and-send sequence.
        // Taking it with `UnsafeMutablePointer(&list)` yields one that dies at the
        // end of that call, which the compiler flags as a dangling pointer.
        withUnsafeMutablePointer(to: &list) { pointer in
            var packet = MIDIPacketListInit(pointer)
            packet = MIDIPacketListAdd(pointer,
                                       MemoryLayout<MIDIPacketList>.size,
                                       packet, 0, payload.count, &payload)
            _ = MIDIReceived(endpoint, pointer)
        }
    }
}
