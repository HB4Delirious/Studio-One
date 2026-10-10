import CoreMIDI
import Foundation

/// Publishes the playing song's key and tempo, and the Stream Deck's mixer
/// controls, as MIDI from a virtual source named "Studio One".
///
/// Plug-ins have no API a DAW exposes, and the AU/VST protocol has no notion
/// of key — but any automatable parameter can be learned in Logic's Controller
/// Assignments (⌥⇧K). A controller message per song is how the key reaches a
/// tuner. Logic files assignments under the port's name and unique ID, so both
/// are fixed: renaming the port orphans everything already learned.
@MainActor
final class MIDIBridge: ObservableObject {

    static let shared = MIDIBridge()

    /// What went out last, in words — shown in Settings and logged, so "nothing
    /// happened in Logic" can be told apart from "nothing was sent".
    @Published private(set) var lastSent = "Nothing sent yet this session."

    /// What MetaTune on Mic 1 should show after the last key or walk step,
    /// and by when — for the key check (`KeyCheck`) to hold Logic to.
    struct SentKey: Equatable {
        let name: String
        let on: Set<Int>
        let due: Date
    }
    @Published private(set) var sentKey: SentKey?

    /// What the tuners were last told. Kept across launches, so quitting while
    /// they're bypassed still brings them back with the next key.
    @Published private(set) var tunersBypassed = UserDefaults.standard.bool(forKey: MIDIBridge.bypassStateKey) {
        didSet { UserDefaults.standard.set(tunersBypassed, forKey: Self.bypassStateKey) }
    }

    // MARK: - Settings

    static let portName = "Studio One"
    /// Any fixed value will do; CoreMIDI would otherwise pick a new one per
    /// launch, and Logic would see a new device each time.
    private static let endpointID: Int32 = 0x53504F4B

    static let enabledKey = "midiBridgeEnabled"
    static let clockKey = "midiClockEnabled"
    static let catchUpKey = "midiKeyCatchUp"
    nonisolated static let mackieSafeKey = "midiMackieSafe"
    nonisolated static let bypassKey = "midiBypassWithoutKey"
    nonisolated static let bypassInvertedKey = "midiBypassInverted"
    private static let bypassStateKey = "midiTunersBypassed"

    /// Sweep through the range before each key (see `sweep`). On by default.
    static var catchesUp: Bool { UserDefaults.standard.object(forKey: catchUpKey) as? Bool ?? true }

    /// Moves key and scale off CC 20–21 on channel 1, which a Mackie Control
    /// reads as V-Pots — so with one set up in Logic, a song change would turn
    /// mixer knobs. Off by default: switching means learning again.
    nonisolated static var mackieSafe: Bool { UserDefaults.standard.bool(forKey: mackieSafeKey) }

    /// Bypass the tuners while a song has no key. On by default.
    nonisolated static var bypassesWithoutKey: Bool {
        UserDefaults.standard.object(forKey: bypassKey) as? Bool ?? true
    }

    /// For an assignment aimed at an on/off control rather than a bypass.
    nonisolated static var bypassInverted: Bool { UserDefaults.standard.bool(forKey: bypassInvertedKey) }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    private var clockEnabled: Bool { UserDefaults.standard.bool(forKey: Self.clockKey) }

    // MARK: - Controller numbers
    //
    // The tuner's key and scale are the plug-in's (`PitchPlugin`); the mixer's
    // and the song settings' are on channel 16 (`MixerControl`, `SongControl`).

    /// The tempo is pitch bend on the control channel, 16, beside the mixer
    /// and song controls: one message with all fourteen bits, which Logic
    /// learns whole — a pair of controllers it learns only half of.
    nonisolated static let tempoChannel: UInt8 = 15
    /// On each mic's channel; clear of everything else, Mackie-safe or not.
    static let bypassCC: UInt8 = 114

    // MARK: - State

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var ready = false
    private var identityTimer: Timer?
    private var clockTimer: DispatchSourceTimer?

    // Bumped by each new send of their kind, so a sweep still in flight from
    // the last one stops instead of landing after it.
    private var keyGeneration = 0
    private var bypassGeneration = 0
    private var walkGeneration = 0
    private var songGeneration = 0

    // MARK: - Port

    func start() {
        guard !ready else { return }
        let clientStatus = MIDIClientCreate(Self.portName as CFString, nil, nil, &client)
        let sourceStatus = clientStatus == noErr
            ? MIDISourceCreate(client, Self.portName as CFString, &source) : clientStatus
        guard sourceStatus == noErr else {
            // Seen while a previous instance is still letting go of the port.
            Diagnostics.log("midi: port not created (\(sourceStatus)) — trying again")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
            return
        }
        claimIdentity()
        MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, Self.portName as CFString)
        MIDIObjectSetStringProperty(source, kMIDIPropertyModel, Self.portName as CFString)
        ready = true
        Self.liveSource = source
    }

    /// Takes the fixed unique ID, and keeps trying for as long as something
    /// else holds it — the Stream Deck plug-in, which uses the same identity
    /// while this app is closed and lets go when it opens. Giving up would
    /// leave the port on an identity Logic has never been taught.
    private func claimIdentity() {
        guard identityTimer == nil else { return }
        if tryClaimIdentity() { return }
        Diagnostics.log("midi: port identity held elsewhere — waiting for it")
        identityTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                if self.tryClaimIdentity() {
                    timer.invalidate()
                    self.identityTimer = nil
                }
            }
        }
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

    // MARK: - Fast lane

    /// The port, for sending from any thread. An endpoint is a plain number,
    /// set once; `MIDIReceived` is safe from any thread.
    nonisolated(unsafe) private static var liveSource = MIDIEndpointRef()
    nonisolated(unsafe) private static var pendingLabel: String?
    nonisolated private static let labelLock = NSLock()

    /// Puts a Stream Deck dial's tick on the port straight from the network
    /// thread it arrived on — through the main thread, ticks queued behind
    /// drawing and the fader lagged the hand. "Last sent" still shows the
    /// latest, updated at most ten times a second.
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

    // MARK: - Key and tempo

    /// Sends the song's key and tempo, and bypasses or restores the tuners.
    /// `lookupPending`: the key is still being looked up — not the same as
    /// having none, so the tuners are left alone until the answer lands.
    func publish(_ analysis: TrackAnalysis?, lookupPending: Bool = false) {
        guard ready, isEnabled else { return }

        if let key = analysis?.key, let coded = Self.encode(key: key) {
            let landed = sendKey(root: coded.root, minor: coded.minor, reason: "song")
            // Back on only once the new key is in, so nobody is tuned to the
            // sweep on its way there.
            if Self.bypassesWithoutKey, let text = setTunersBypassed(false, after: landed) {
                appendNote(text)
            }
        } else if lookupPending {
            note("Still looking up this song's key.")
        } else {
            note("No key for this song, so no key was sent" + (analysis?.key.map { " (couldn't read “\($0)”)" } ?? "") + ".")
            if Self.bypassesWithoutKey, let text = setTunersBypassed(true) {
                appendNote(text)
            }
        }

        if let tempo = analysis?.tempo, tempo > 0 {
            appendNote(sendTempo(tempo))
        }
        setClock(bpm: analysis?.tempo)
    }

    /// A key picked in Settings, sent at once, to check the plug-in by eye.
    func sendTest(root: Int, minor: Bool) {
        guard ready, isEnabled else { return }
        sendKey(root: root, minor: minor, reason: "test")
    }

    /// The key, shaped for the chosen plug-in, on every mic's channel.
    /// Returns how long until it has landed.
    @discardableResult
    private func sendKey(root: Int, minor: Bool, reason: String) -> TimeInterval {
        let plugin = PitchPlugin.current
        let perTuner = plugin.messages(root: root, minor: minor,
                                       invertNotes: PitchPlugin.invertsNotes, reading: plugin.reading)
        let messages = (0..<PitchPlugin.tunerCount).flatMap { channel in
            perTuner.map { (status: 0xB0 | UInt8(channel), cc: $0.cc, value: $0.value) }
        }
        keyGeneration += 1
        let generation = keyGeneration
        let landed = sweep(messages, through: Self.catchesUp ? Self.fullRange : []) { [weak self] in
            self?.keyGeneration == generation
        }

        let key = "\(PitchPlugin.noteNames[root]) \(minor ? "minor" : "major") (\(reason))"
        if plugin.scheme == .noteSwitches {
            sentKey = SentKey(name: "\(PitchPlugin.noteNames[root]) \(minor ? "minor" : "major")",
                              on: PitchPlugin.notes(root: root, minor: minor),
                              due: Date().addingTimeInterval(landed + 1.5))
            // By note name: "C off" is what MetaTune should show.
            let lists = PitchPlugin.noteLists(root: root, minor: minor)
            note("\(key) → MetaTune: on \(lists.on.joined(separator: " ")) · off \(lists.off.joined(separator: " "))\(PitchPlugin.invertsNotes ? " (sent inverted)" : "") on \(Self.micChannels).")
        } else {
            let values = perTuner.map { "CC \($0.cc) = \($0.value)" }.joined(separator: ", ")
            note("\(key) → \(values) on \(Self.micChannels).")
        }
        return landed
    }

    /// The tempo alone, to check Logic against the song.
    func sendTempoNow(_ analysis: TrackAnalysis?) {
        guard ready, isEnabled else { return }
        guard let tempo = analysis?.tempo, tempo > 0 else {
            note("No tempo for this song, so none was sent.")
            return
        }
        note(sendTempo(tempo))
    }

    /// Returns what to report.
    private func sendTempo(_ tempo: Double) -> String {
        let bpm = Self.logicTempo(for: tempo)
        let bend = Self.pitchBend(for: bpm)
        Self.transmit(Self.tempoMessage(bend), from: source)
        let rounded = abs(tempo - Double(bpm)) >= 0.05
            ? String(format: " (the song's %.1f, to the whole BPM Logic keeps)", tempo) : ""
        return "Tempo \(bpm) BPM\(rounded) → pitch bend \(bend) on channel \(Self.tempoChannel + 1)."
    }

    // MARK: - Bypass with no key

    private static func bypassValue(_ bypassed: Bool) -> UInt8 {
        bypassed != bypassInverted ? 127 : 0
    }

    /// Bypasses every mic's tuner, or restores it — only when that's a change,
    /// unless `force`d. Returns what was sent, in words.
    ///
    /// Each change goes out as the opposite value, then the new one. With the
    /// tuner where Studio One left it, the first changes nothing; a Direct or
    /// Scaled assignment lands on the second, one in Pickup mode is caught by
    /// the first, and one Logic learned as a toggle flips exactly once.
    private func setTunersBypassed(_ bypassed: Bool, force: Bool = false,
                                   after delay: TimeInterval = 0) -> String? {
        bypassGeneration += 1
        guard force || bypassed != tunersBypassed else { return nil }
        let generation = bypassGeneration
        let endpoint = source
        let value = Self.bypassValue(bypassed)
        let transmit: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.bypassGeneration == generation else { return }
            self.tunersBypassed = bypassed
            for channel in 0..<PitchPlugin.tunerCount {
                for sent in [127 - value, value] {
                    Self.transmit([0xB0 | UInt8(channel), Self.bypassCC, sent], from: endpoint)
                }
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: transmit)
        } else {
            transmit()
        }
        return "\(bypassed ? "Tuners bypassed" : "Tuners back on") → CC \(Self.bypassCC) = \(value) on \(Self.micChannels)."
    }

    /// Settings' test buttons. Sent whatever the tuners were last told, so a
    /// tuner switched by hand in Logic can be brought back in line.
    func sendBypass(_ bypassed: Bool) {
        guard ready, isEnabled, let text = setTunersBypassed(bypassed, force: true) else { return }
        note("Test: " + text)
    }

    /// Switching the feature off mustn't strand the tuners bypassed.
    func bypassTurnedOff() {
        guard ready, isEnabled, tunersBypassed,
              let text = setTunersBypassed(false, force: true) else { return }
        note("Bypass with no key turned off: " + text)
    }

    // MARK: - Learning

    enum LearnTarget: Equatable {
        case key, mode
        /// The tuner's bypass, for songs with no key.
        case bypass
        /// One of MetaTune's twelve note switches, 0 = C.
        case note(Int)

        var name: String {
            switch self {
            case .key:             return "key"
            case .mode:            return "scale"
            case .bypass:          return "bypass"
            case .note(let pitch): return "\(PitchPlugin.noteNames[pitch]) switch"
            }
        }
    }

    /// Something for Logic's Learn Mode to bind to, on demand: one controller
    /// swept across its range — Learn Mode waits for a control to move — then
    /// left at the value in use. `tuner` picks the mic's channel. Works with
    /// nothing playing, so assignments can be set up before the first song.
    func sendForLearn(_ analysis: TrackAnalysis?, control: LearnTarget, tuner: Int = 0) {
        guard ready, isEnabled else { return }

        let plugin = PitchPlugin.current
        let keyMessages = analysis?.key.flatMap(Self.encode(key:)).map {
            plugin.messages(root: $0.root, minor: $0.minor,
                            invertNotes: PitchPlugin.invertsNotes, reading: plugin.reading)
        } ?? []
        let channel = UInt8(min(max(tuner, 0), 15))

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
            // Left on whatever the song: settling to the song's key put an
            // out-of-key switch straight back out, which looked like a failed
            // learn. The key is applied with the next song.
            cc = PitchPlugin.noteCC(pitchClass)
            settled = PitchPlugin.invertsNotes ? 0 : 127
        case .bypass:
            // Where the tuners were last told to be, so Logic and Studio One
            // agree from the start.
            cc = Self.bypassCC
            settled = Self.bypassValue(tunersBypassed)
        }
        sweep([(0xB0 | channel, cc, settled)], through: Self.fullRange)

        let mic = PitchPlugin.tunerCount == 1 ? "" : " for Mic \(Int(channel) + 1)"
        let left = control == .bypass ? ", left \(tunersBypassed ? "bypassed" : "on")" : ""
        note("Learn: \(control.name)\(mic) → CC \(cc) on channel \(Int(channel) + 1), swept 0–127\(left).")
    }

    /// Pitch bend from one end to the other, then the song's tempo (or 120),
    /// for Logic's Learn Mode, which waits for a control to move. Logic learns
    /// it as `EF Lo7 Hi7`, all fourteen bits, and needs only pointing at the
    /// tempo afterwards.
    func learnTempo(_ analysis: TrackAnalysis?) {
        guard ready, isEnabled else { return }
        let endpoint = source
        let settled = Self.pitchBend(for: Self.logicTempo(for: analysis?.tempo ?? 120))
        for (step, bend) in [0, 4_096, 8_192, 12_288, 16_383, settled].enumerated() {
            let message = Self.tempoMessage(bend)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.04) {
                Self.transmit(message, from: endpoint)
            }
        }
        note("Learn: tempo → pitch bend on channel \(Self.tempoChannel + 1), swept end to end.")
    }

    /// Lights each of MetaTune's note switches alone, C to B, on one mic's
    /// channel, then puts the song's key back — so a switch learned wrongly,
    /// or not at all, shows itself. Each switch goes to both ends before
    /// landing, to get past Pickup mode.
    func walkNoteSwitches(tuner: Int, restoring analysis: TrackAnalysis?) {
        guard ready, isEnabled else { return }
        walkGeneration += 1
        keyGeneration += 1            // stops any key sweep still in flight
        let generation = walkGeneration
        let channel = UInt8(min(max(tuner, 0), 15))
        let endpoint = source
        let inverted = PitchPlugin.invertsNotes
        for step in 0...12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.9) { [weak self] in
                guard let self, self.walkGeneration == generation else { return }
                guard step < 12 else {
                    if analysis?.key != nil { self.publish(analysis) }
                    else { self.note("Walk done. Nothing is playing, so no key was put back.") }
                    return
                }
                for pitchClass in 0..<12 {
                    let on = (pitchClass == step) != inverted
                    for value: UInt8 in [0, 127, on ? 127 : 0] {
                        Self.transmit([0xB0 | channel, PitchPlugin.noteCC(pitchClass), value], from: endpoint)
                    }
                }
                self.note("Walking the switches, Mic \(Int(channel) + 1): \(PitchPlugin.noteNames[step]) alone should be lit (CC \(PitchPlugin.noteCC(step))).")
                if channel == 0 {
                    // Each step checked before the next: a switch learned
                    // wrongly shows up by name.
                    self.sentKey = SentKey(name: "\(PitchPlugin.noteNames[step]) alone (walk)", on: [step],
                                           due: Date().addingTimeInterval(0.8))
                }
            }
        }
    }

    // MARK: - Mixer

    /// One step of a mic-channel dial. Not gated on `isEnabled`, which is
    /// about publishing key and tempo by itself; this is someone turning a dial.
    func sendMixer(_ control: MixerControl, ticks: Int) {
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

    /// Any controller message, for the Stream Deck's assignable actions — on
    /// this port, so an assignment answers whether it came from here or from
    /// the deck sending it itself.
    func sendRaw(cc: UInt8, value: UInt8, channel: UInt8, label: String?) {
        guard ready else { return }
        send(cc: cc, value: value, channel: channel)
        note("\(label ?? "MIDI") → CC \(cc) = \(value) on channel \(channel + 1).")
    }

    /// For Learn Mode: a dial has to be seen turning both ways to be taken for
    /// an encoder, and a button pressed and released.
    func sendMixerForLearn(_ control: MixerControl) {
        guard ready else { return }
        let endpoint = source
        let steps: [UInt8] = control.kind == .dial
            ? Array(repeating: MixerControl.value(forTicks: 1), count: 6)
                + Array(repeating: MixerControl.value(forTicks: -1), count: 2)
            : [127, 0, 127, 0]
        for (index, value) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.06) {
                Self.transmit([0xB0 | MixerControl.channel, control.cc, value], from: endpoint)
            }
        }
        note("Learn: \(control.name) on CC \(control.cc), channel \(MixerControl.channel + 1).")
    }

    // MARK: - Song controls

    /// A song's plug-in settings as it starts (see `SongControl`), swept like
    /// the key — unless `sweep` is off, for a slider being dragged, which
    /// passes through the values by itself.
    func sendSongControls(_ messages: [(cc: UInt8, value: UInt8)], sweep sweeping: Bool, label: String) {
        guard ready, isEnabled, !messages.isEmpty else { return }
        songGeneration += 1
        let generation = songGeneration
        sweep(messages.map { (0xB0 | SongControl.channel, $0.cc, $0.value) },
              through: sweeping && Self.catchesUp ? Self.fullRange : []) { [weak self] in
            self?.songGeneration == generation
        }
        let values = messages.map { "CC \($0.cc) = \($0.value)" }.joined(separator: ", ")
        note("\(label) → \(values) on channel \(SongControl.channel + 1).")
    }

    func sendSongControlForLearn(slot: Int, settle: Int) {
        guard ready else { return }
        let cc = SongControl.cc(slot)
        sweep([(0xB0 | SongControl.channel, cc, UInt8(min(127, max(0, settle))))], through: Self.fullRange)
        note("Learn: song control \(slot + 1) on CC \(cc), channel \(SongControl.channel + 1).")
    }

    // MARK: - Clock

    /// MIDI beat clock, off unless chosen: Logic only follows it in external
    /// sync, which slaves its transport as well as its tempo.
    func setClock(bpm: Double?) {
        stopClock()
        guard ready, isEnabled, clockEnabled, let bpm, bpm > 20, bpm < 400 else { return }
        let endpoint = source
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        // 24 pulses per quarter note.
        timer.schedule(deadline: .now(), repeating: 60.0 / (bpm * 24.0), leeway: .nanoseconds(100_000))
        timer.setEventHandler { Self.transmit([0xF8], from: endpoint) }
        timer.resume()
        clockTimer = timer
    }

    func stopClock() {
        clockTimer?.cancel()
        clockTimer = nil
    }

    // MARK: - "Last sent"

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    private func note(_ text: String) {
        lastSent = "\(Self.clock.string(from: Date()))  \(text)"
        Diagnostics.log("midi: \(text)")
    }

    /// Adds to the line just written, for something sent at the same moment.
    private func appendNote(_ text: String) {
        lastSent += "  " + text
        Diagnostics.log("midi: \(text)")
    }

    /// "channel 1", or "channels 1–2, one per mic".
    private static var micChannels: String {
        PitchPlugin.tunerCount == 1 ? "channel 1" : "channels 1–\(PitchPlugin.tunerCount), one per mic"
    }

    // MARK: - Transmission

    /// Values from one end of the range to the other.
    private static let fullRange: [UInt8] = [0, 21, 42, 64, 85, 106, 127]

    /// Sends every message at each of `values` in turn, 40 ms apart, then at
    /// its own value; returns when that lands. Logic's Pickup mode ignores a
    /// jump to a new value until the controller passes the parameter's
    /// current one, and Learn Mode waits for a control to move — a run across
    /// the range gets past both. Stops early once `current` says a newer send
    /// has taken over.
    @discardableResult
    private func sweep(_ messages: [(status: UInt8, cc: UInt8, value: UInt8)], through values: [UInt8],
                       while current: @escaping @MainActor () -> Bool = { true }) -> TimeInterval {
        let endpoint = source
        let steps = values.map { Optional($0) } + [nil]
        for (step, value) in steps.enumerated() {
            let send: @MainActor @Sendable () -> Void = {
                guard current() else { return }
                for message in messages {
                    Self.transmit([message.status, message.cc, value ?? message.value], from: endpoint)
                }
            }
            if step == 0 { send() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.04, execute: send)
            }
        }
        return Double(steps.count) * 0.04
    }

    private func send(cc: UInt8, value: UInt8, channel: UInt8 = 0) {
        Self.transmit([0xB0 | (channel & 0x0F), cc, min(127, value)], from: source)
    }

    /// Callable from any thread — the clock's timer and the fast lane send
    /// from their own.
    nonisolated static func transmit(_ bytes: [UInt8], from endpoint: MIDIEndpointRef) {
        var payload = bytes
        var list = MIDIPacketList()
        // One pointer for the whole build-and-send: `UnsafeMutablePointer(&list)`
        // would dangle after its first use.
        withUnsafeMutablePointer(to: &list) { pointer in
            var packet = MIDIPacketListInit(pointer)
            packet = MIDIPacketListAdd(pointer, MemoryLayout<MIDIPacketList>.size,
                                       packet, 0, payload.count, &payload)
            _ = MIDIReceived(endpoint, pointer)
        }
    }
}

// MARK: - Encoding

extension MIDIBridge {

    /// Logic's tempo range. An assignment spreads pitch bend's 0–16383 across
    /// it evenly — measured in Logic 12: 0 is 5 BPM, 8192 is 498, 16383 is 990.
    nonisolated static let logicTempoRange = 5...990

    /// What Logic will take: it keeps a tempo from a controller to the whole
    /// BPM, so 124.3 arrives as 124 whatever the resolution sent.
    nonisolated static func logicTempo(for bpm: Double) -> Int {
        min(logicTempoRange.upperBound, max(logicTempoRange.lowerBound, Int(bpm.rounded())))
    }

    /// The pitch bend Logic scales to `bpm` — within 0.03 BPM, so it can only
    /// round to that whole number.
    nonisolated static func pitchBend(for bpm: Int) -> Int {
        let span = Double(logicTempoRange.upperBound - logicTempoRange.lowerBound)
        return Int((Double(bpm - logicTempoRange.lowerBound) / span * 16_383).rounded())
    }

    /// Pitch bend carries its value low seven bits first.
    nonisolated static func tempoMessage(_ bend: Int) -> [UInt8] {
        [0xE0 | tempoChannel, UInt8(bend & 0x7F), UInt8(bend >> 7)]
    }

    /// "F♯m" → (6, minor). Takes ♯/♭ or #/b, and reads the quality after the
    /// note: "m", "min", "minor" and "m7" are minor; "maj", "major" and a
    /// capital "M" are major.
    nonisolated static func encode(key: String) -> (root: Int, minor: Bool)? {
        let text = key.trimmingCharacters(in: .whitespaces)
        let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let head = text.first, var index = naturals[Character(head.uppercased())] else { return nil }

        var rest = text.dropFirst()
        if rest.hasPrefix("♯") || rest.hasPrefix("#") { index += 1; rest = rest.dropFirst() }
        else if rest.hasPrefix("♭") || rest.hasPrefix("b") { index -= 1; rest = rest.dropFirst() }

        let quality = rest.trimmingCharacters(in: .whitespaces)
        let lowered = quality.lowercased()
        let capitalMajor = quality.hasPrefix("M") && !lowered.hasPrefix("mi")
        let minor = lowered.hasPrefix("m") && !lowered.hasPrefix("maj") && !capitalMajor
        return ((index % 12 + 12) % 12, minor)
    }

    /// The inverse of `encode`, in sharps, so nudging a key never flips its
    /// spelling mid-song.
    static func decode(root: Int, minor: Bool) -> String {
        PitchPlugin.noteNames[((root % 12) + 12) % 12] + (minor ? "m" : "")
    }
}
