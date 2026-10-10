import Foundation
import Network

// Studio One for Stream Deck.
//
// A native plug-in: the Stream Deck app starts this executable with the port of
// its WebSocket and an identity to register under, then sends key, dial and
// touch events over that socket and accepts titles, images and touch-strip
// feedback back. Elgato's own examples include native executables alongside
// Node scripts; this one is Swift so it builds with nothing the app's own
// build doesn't already need.
//
// Studio One is reached through its control port on 127.0.0.1. The port and
// token are read from the file Studio One writes, so nothing is configured.

// MARK: - Launch arguments

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

// Plain top-level constants rather than `guard let`: a class can't capture
// values bound by top-level control flow, but it can read globals.
let deckPort = argument("-port") ?? ""
let pluginUUID = argument("-pluginUUID") ?? ""
let registerEvent = argument("-registerEvent") ?? ""
if deckPort.isEmpty || pluginUUID.isEmpty || registerEvent.isEmpty {
    FileHandle.standardError.write(Data("Studio One: started without Stream Deck's arguments\n".utf8))
    exit(1)
}

let prefix = "com.logan.studioone."

// MARK: - Studio One client

/// The control port, found through the file Studio One writes on launch.
final class StudioOne {
    private var port: Int?
    private var token: String?
    private var midiPort: Int?
    private var lane: NWConnection?
    private let laneQueue = DispatchQueue(label: "com.logan.studioone.lane", qos: .userInteractive)
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    static var infoURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Studio One/control.json")
    }

    /// Re-read every time a request fails: Studio One may have been restarted
    /// on a different port.
    private func loadInfo() -> Bool {
        guard let data = try? Data(contentsOf: Self.infoURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, let token = object["token"] as? String else { return false }
        self.port = port
        self.token = token
        let midiPort = object["midiPort"] as? Int
        if midiPort != self.midiPort {
            lane?.cancel()
            lane = nil
            self.midiPort = midiPort
        }
        return true
    }

    private func request(_ path: String, body: [String: Any]? = nil,
                         done: @escaping (Data?, Int) -> Void) {
        if port == nil, !loadInfo() { return done(nil, 0) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.setValue(token, forHTTPHeaderField: "X-Studio-One-Token")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        session.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 0 || status == 401 {                         // look again next time
                // All on the main thread, where they're read; clearing the
                // port from URLSession's queue raced the next request.
                DispatchQueue.main.async {
                    self?.port = nil
                    self?.lane?.cancel(); self?.lane = nil; self?.midiPort = nil
                }
            }
            DispatchQueue.main.async { done(data, status) }
        }.resume()
    }

    /// Sends one controller message down Studio One's MIDI lane: a single
    /// datagram, no connection to open and no reply to wait for. False when
    /// there is no lane to use, and the caller falls back to the control port.
    func tick(status: UInt8, cc: UInt8, value: UInt8, label: String) -> Bool {
        if port == nil { _ = loadInfo() }
        guard let midiPort, let token, let endpointPort = NWEndpoint.Port(rawValue: UInt16(midiPort)) else {
            return false
        }
        if lane == nil {
            let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .udp)
            connection.start(queue: laneQueue)
            lane = connection
        }
        var datagram = Data(token.utf8)
        datagram.append(contentsOf: [0x0A, status, cc, value])
        datagram.append(Data(label.utf8.prefix(80)))
        lane?.send(content: datagram, completion: .idempotent)
        return true
    }

    func state(_ done: @escaping ([String: Any]?) -> Void) {
        request("/state") { data, status in
            done(status == 200 ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil)
        }
    }

    /// The state after the command, or the reason it failed.
    func command(_ name: String, amount: Double = 0, control: String? = nil,
                 fields: [String: Any] = [:],
                 _ done: @escaping ([String: Any]?, String?) -> Void) {
        var body: [String: Any] = ["command": name, "amount": amount]
        if let control { body["control"] = control }
        for (key, value) in fields { body[key] = value }
        request("/command", body: body) { data, status in
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if status == 200 { done(object?["state"] as? [String: Any], nil) }
            else { done(nil, object?["error"] as? String ?? (status == 0 ? "Studio One isn't open" : "HTTP \(status)")) }
        }
    }

    /// What the dials can be pointed at, and how steps are written — the step
    /// format is a property of the whole set, not of one control.
    func controls(_ done: @escaping ([[String: Any]], String?) -> Void) {
        request("/controls") { data, status in
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done(object?["controls"] as? [[String: Any]] ?? [], object?["step"] as? String)
        }
    }

    func artwork(_ done: @escaping (Data?) -> Void) {
        request("/artwork") { data, status in done(status == 200 ? data : nil) }
    }
}

// MARK: - Stream Deck connection

final class Deck: NSObject, URLSessionWebSocketDelegate {
    private var socket: URLSessionWebSocketTask!
    private let studio = StudioOne()

    /// Every action on screen: context → action UUID.
    private var visible: [String: String] = [:]
    /// What was last sent to each context, so a poll that changes nothing sends nothing.
    private var lastSent: [String: String] = [:]
    private var state: [String: Any]?
    /// Per action: which Logic control it drives, chosen in its settings.
    private var settings: [String: [String: Any]] = [:]
    private var controls: [[String: Any]] = []
    /// The last nudge shown on a dial. A step-based control has no position to
    /// report, so this is what it did, not where it is.
    private var lastMove: [String: String] = [:]
    private var artworkTrack: String?
    private var artworkURL: String?
    private var artworkTries = 0
    private var artworkAskedAt = Date.distantPast
    private var pollTimer: Timer?

    /// The deck's own port, used only while Studio One is away. See `MIDIOut`.
    private let midi = MIDIOut()
    private var studioOneUp = false
    /// Remembered from the last time Studio One was reachable, so its mixer
    /// controls still send correctly when it isn't.
    private var mixerStep = UserDefaults.standard.string(forKey: "mixerStep") ?? "signMagnitude"

    func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(deckPort)")!)
        socket.resume()
        send(["event": registerEvent, "uuid": pluginUUID])
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        exit(0)   // Stream Deck quit or unloaded the plug-in.
    }

    private func receive() {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                if let data = text.data(using: .utf8),
                   let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(event)
                }
                self.receive()
            case .success:
                self.receive()
            case .failure:
                exit(0)
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func log(_ message: String) {
        send(["event": "logMessage", "payload": ["message": "Studio One: \(message)"]])
    }

    // MARK: Events

    private func handle(_ event: [String: Any]) {
        guard let name = event["event"] as? String else { return }
        let context = event["context"] as? String ?? ""
        let action = (event["action"] as? String ?? "").replacingOccurrences(of: prefix, with: "")
        let payload = event["payload"] as? [String: Any] ?? [:]

        switch name {
        case "willAppear":
            visible[context] = action
            settings[context] = payload["settings"] as? [String: Any] ?? [:]
            // A key coming back (a page switch) has been cleared by Stream Deck;
            // forget what it last showed, or the redraw would be skipped as a repeat.
            forget(context)
            startPolling()
            if let state { render(context, action, state) } else { poll() }
        case "willDisappear":
            visible[context] = nil
            forget(context)
            if visible.isEmpty {
                pollTimer?.invalidate()
                pollTimer = nil
                // Nothing left to send with, so let go of the port: while this
                // holds it, Studio One would launch into a random identity.
                midi.close()
            }
        case "keyDown":
            keyDown(context, action)
        case "dialRotate":
            let ticks = (payload["ticks"] as? NSNumber)?.doubleValue ?? 0
            dialRotate(context, action, ticks)
        case "dialDown":
            dialPush(context, action)
        case "touchTap":
            touch(context, action, hold: payload["hold"] as? Bool ?? false)
        case "didReceiveSettings":
            settings[context] = payload["settings"] as? [String: Any] ?? [:]
            forget(context)
            if let state { render(context, action, state) }
        case "propertyInspectorDidAppear":
            offerControls(to: context)
        case "sendToPlugin":
            if (payload["request"] as? String) == "controls" { offerControls(to: context) }
        case "systemDidWakeUp":
            poll()
        default:
            break
        }
    }

    private func keyDown(_ context: String, _ action: String) {
        switch action {
        case "playpause":     run("playPause", context)
        case "next":          run("next", context)
        case "previous":      run("previous", context)
        case "fadeout":       run("fadeOut", context)
        case "nowplaying":    run("showLyrics", context)
        case "keybpm":        run("sendKey", context, confirm: true)
        case "lyricsfull":    run("lyricsFullScreen", context)
        case "source":        run("toggleSource", context)
        case "reload":        run("reloadLyrics", context, confirm: true)
        case "logic.mute":
            guard let wiring = wiring(context) else { return alert(context) }
            sendMIDI(context, cc: wiring.cc, channel: wiring.channel, value: 127,
                     label: wiring.label, confirm: true)
        case "midi.key":
            guard let wiring = wiring(context) else { return alert(context) }
            let value = (settings[context]?["value"] as? NSNumber)?.intValue ?? 127
            sendMIDI(context, cc: wiring.cc, channel: wiring.channel, value: value,
                     label: wiring.label, confirm: true)
        default: break
        }
    }

    /// The control an action was set to, if its settings have been filled in.
    private func chosen(_ context: String) -> String? {
        (settings[context]?["control"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func alert(_ context: String) {
        send(["event": "showAlert", "context": context])
    }

    /// Hands the settings panel the list to choose from. Fetched once, then
    /// kept — the list only changes when the number of mics does.
    private func offerControls(to context: String) {
        func deliver() {
            send(["event": "sendToPropertyInspector", "context": context,
                  "payload": ["controls": controls]])
        }
        if controls.isEmpty {
            studio.controls { [weak self] list, step in
                self?.controls = list
                if let step { self?.mixerStep = step }
                deliver()
            }
        } else {
            deliver()
        }
    }

    private func dialRotate(_ context: String, _ action: String, _ ticks: Double) {
        switch action {
        case "dial.key":      run("keyBy", context, amount: ticks)
        case "dial.tempo":    run("tempoBy", context, amount: ticks)
        case "dial.sync":     run("lyricsBy", context, amount: ticks * 50)
        case "dial.volume":   run("volumeBy", context, amount: ticks * 2)
        case "dial.seek":     run("seekBy", context, amount: ticks * 5)
        case "dial.font":     run("fontBy", context, amount: ticks * 2)
        case "logic.mixer":
            guard let wiring = wiring(context) else { return alert(context) }
            lastMove[context] = ticks > 0 ? "▲ \(Int(ticks))" : "▼ \(Int(-ticks))"
            sendMIDI(context, cc: wiring.cc, channel: wiring.channel,
                     value: MIDIOut.relativeValue(ticks: Int(ticks), step: mixerStep),
                     label: wiring.label)
            render(context, "logic.mixer", state ?? [:])

        case "midi.dial":
            guard let wiring = wiring(context) else { return alert(context) }
            let settings = settings[context] ?? [:]
            let size = (settings["step"] as? NSNumber)?.intValue ?? 1
            let move = Int(ticks) * max(1, size)
            if (settings["mode"] as? String) == "absolute" {
                // The deck holds the value, because nothing reports one back.
                let now = min(127, max(0, ((settings["value"] as? NSNumber)?.intValue ?? 64) + move))
                self.settings[context]?["value"] = now
                send(["event": "setSettings", "context": context, "payload": self.settings[context] ?? [:]])
                sendMIDI(context, cc: wiring.cc, channel: wiring.channel, value: now, label: wiring.label)
            } else {
                lastMove[context] = move > 0 ? "▲ \(move)" : "▼ \(-move)"
                sendMIDI(context, cc: wiring.cc, channel: wiring.channel,
                         value: MIDIOut.relativeValue(ticks: move, step: mixerStep), label: wiring.label)
            }
            render(context, "midi.dial", state ?? [:])
        default: break
        }
    }

    private func dialPush(_ context: String, _ action: String) {
        switch action {
        case "dial.key":      run("keyReset", context)
        case "dial.tempo":    run("tempoReset", context)
        case "dial.sync":     run("lyricsReset", context)
        case "dial.volume":   run("volumeMute", context)
        case "dial.seek":     run("playPause", context)
        case "dial.font":     run("fontReset", context)
        case "logic.mixer":
            // Press mutes that mic. Its controller number is saved with the
            // action alongside the dial's own, so this works with Studio One shut.
            guard let cc = (settings[context]?["muteCC"] as? NSNumber)?.intValue,
                  let wiring = wiring(context) else { return alert(context) }
            sendMIDI(context, cc: cc, channel: wiring.channel, value: 127,
                     label: settings[context]?["muteName"] as? String ?? wiring.label, confirm: true)
        case "midi.dial":
            // Press sends the same controller at 127: a button on the same
            // assignment, for anything learned as a toggle.
            guard let wiring = wiring(context) else { return alert(context) }
            sendMIDI(context, cc: wiring.cc, channel: wiring.channel, value: 127,
                     label: wiring.label, confirm: true)
        default: break
        }
    }

    private func touch(_ context: String, _ action: String, hold: Bool) {
        switch action {
        case "dial.key":      run("sendKey", context, confirm: true)
        case "dial.tempo":    run(hold ? "tempoHalf" : "tempoDouble", context)
        // Tap as a line starts to sync to it; hold to look the lyrics up again.
        case "dial.sync":     run(hold ? "reloadLyrics" : "syncNow", context, confirm: true)
        case "dial.seek":     run(hold ? "previous" : "next", context)
        default: break
        }
    }

    /// Sends a command and redraws everything from the state it returns, so a
    /// turn of the dial shows up at once rather than on the next poll.
    private func run(_ command: String, _ context: String, amount: Double = 0,
                     control: String? = nil, fields: [String: Any] = [:], confirm: Bool = false) {
        studio.command(command, amount: amount, control: control, fields: fields) { [weak self] state, error in
            guard let self else { return }
            if let error {
                self.log("\(command): \(error)")
                self.send(["event": "showAlert", "context": context])
                return
            }
            if confirm { self.send(["event": "showOk", "context": context]) }
            if let state { self.apply(state) }
        }
    }

    // MARK: Polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        studio.state { [weak self] state in
            guard let self else { return }
            if let state { self.apply(state) } else { self.showOffline() }
        }
    }

    private func apply(_ state: [String: Any]) {
        self.state = state
        if !studioOneUp {
            studioOneUp = true
            // Studio One owns the port again; ours has to let go of it.
            midi.close()
            studio.controls { [weak self] list, step in
                guard let self else { return }
                if !list.isEmpty { self.controls = list }
                if let step {
                    self.mixerStep = step
                    // Kept for next launch: with Studio One shut there is
                    // nowhere to ask, and the wrong format nudges the wrong way.
                    UserDefaults.standard.set(step, forKey: "mixerStep")
                }
            }
        }
        let track = state["trackID"] as? String
        if track != artworkTrack {
            artworkTrack = track
            artworkURL = nil
            artworkTries = 0
        }
        // Asked again while there's none, a few times, a second or two apart:
        // on Apple Music the cover arrives a moment after the song changes,
        // and asked once, too early, the key showed no picture all song.
        if let track, artworkURL == nil, artworkTries < 5,
           Date().timeIntervalSince(artworkAskedAt) > 1.5 {
            artworkTries += 1
            artworkAskedAt = Date()
            studio.artwork { [weak self] data in
                guard let self, self.artworkTrack == track, let data else { return }
                self.artworkURL = "data:image/png;base64," + data.base64EncodedString()
                self.renderAll()
            }
        }
        renderAll()
    }

    private func renderAll() {
        guard let state else { return }
        for (context, action) in visible { render(context, action, state) }
    }

    private func showOffline() {
        state = nil
        studioOneUp = false
        // Tried on every poll, not once: the identity can be held for a moment
        // by a port an earlier run left behind, and one failed attempt would
        // otherwise leave the dials dead until Stream Deck restarted.
        if !midi.isOpen { midi.open() }
        for (context, action) in visible {
            // The Logic controls don't need Studio One: they are MIDI, and the
            // deck can send it itself. Only the ones that drive the app go dark.
            if action.hasPrefix("logic.") || action.hasPrefix("midi.") {
                render(context, action, [:])
            } else if action.hasPrefix("dial.") {
                feedback(context, ["title": "Studio One", "value": "Not open", "indicator": ["value": 0]])
            } else {
                title(context, "Studio One\nnot open")
            }
        }
    }

    /// One controller message, through Studio One when it is there and straight
    /// out of the deck's own port when it isn't.
    private func sendMIDI(_ context: String, cc: Int, channel: Int, value: Int,
                          label: String?, confirm: Bool = false) {
        if studioOneUp {
            let status = 0xB0 | UInt8((max(1, min(16, channel)) - 1) & 0x0F)
            if studio.tick(status: status, cc: UInt8(max(0, min(127, cc))),
                           value: UInt8(max(0, min(127, value))), label: label ?? "MIDI") {
                if confirm { send(["event": "showOk", "context": context]) }
                return
            }
            run("midi", context, fields: ["cc": cc, "channel": channel, "value": value,
                                          "label": label ?? "MIDI"], confirm: confirm)
            return
        }
        guard midi.isOpen || midi.open() else {
            log("the MIDI port is held by something else")
            return alert(context)
        }
        midi.send(cc: cc, value: value, channel: channel)
        if confirm { send(["event": "showOk", "context": context]) }
    }

    /// What a Logic action was set to. The controller number and channel are
    /// saved with the action, so they are known with Studio One shut.
    private func wiring(_ context: String) -> (cc: Int, channel: Int, label: String)? {
        guard let settings = settings[context],
              let cc = (settings["cc"] as? NSNumber)?.intValue else { return nil }
        let channel = (settings["channel"] as? NSNumber)?.intValue ?? 16
        return (cc, channel, settings["name"] as? String ?? settings["label"] as? String ?? "MIDI")
    }

    // MARK: Drawing

    private func render(_ context: String, _ action: String, _ s: [String: Any]) {
        let playing = s["playing"] as? Bool ?? false
        let key = s["key"] as? String
        let bpm = (s["bpm"] as? NSNumber)?.doubleValue
        let multiplier = (s["tempoMultiplier"] as? NSNumber)?.doubleValue ?? 1
        let position = (s["position"] as? NSNumber)?.doubleValue ?? 0
        let duration = (s["duration"] as? NSNumber)?.doubleValue ?? 0

        switch action {
        case "playpause":
            setState(context, playing ? 1 : 0)
            title(context, "")
        case "next", "previous", "lyricsfull", "reload":
            title(context, "")
        case "nowplaying":
            image(context, artworkURL)
            title(context, artworkURL == nil ? short(s["title"] as? String ?? "Nothing\nplaying", 18) : "")
        case "keybpm":
            let bpmText = bpm.map { "\(Int($0.rounded()))" } ?? "—"
            title(context, "\(key ?? "—")\n\(bpmText) BPM")
        case "source":
            title(context, (s["source"] as? String) == "spotify" ? "Spotify" : "Apple\nMusic")

        case "dial.key":
            let manual = s["keyIsManual"] as? Bool ?? false
            let shift = Keys.shift(from: s["detectedKey"] as? String, to: key)
            let shiftText = shift.map { $0 == 0 ? "" : String(format: " (%+d)", $0) } ?? ""
            feedback(context, ["title": manual ? "KEY · manual" : "KEY",
                               "value": (key ?? "—") + shiftText,
                               "indicator": ["value": Int((Double((shift ?? 0) + 6) / 12 * 100).rounded())]])
        case "dial.tempo":
            let times = multiplier == 1 ? "" : (multiplier > 1 ? " ×\(Int(multiplier))" : " ÷\(Int(1 / multiplier))")
            let manual = s["tempoIsManual"] as? Bool ?? false
            feedback(context, ["title": manual ? "TEMPO · manual" : "TEMPO",
                               "value": (bpm.map { "\(Int($0.rounded())) BPM" } ?? "—") + times,
                               "indicator": ["value": Int(min(100, max(0, ((bpm ?? 60) - 60) / 120 * 100)))]])
        case "dial.sync":
            let offset = (s["lyricOffsetMs"] as? NSNumber)?.doubleValue ?? 0
            feedback(context, ["title": "LYRIC SYNC",
                               "value": offset == 0 ? "In sync" : String(format: "%+.0f ms", offset),
                               "indicator": ["value": Int(min(100, max(0, (offset + 1000) / 2000 * 100)))]])
        case "dial.volume":
            let volume = (s["volume"] as? NSNumber)?.intValue
            feedback(context, ["title": "VOLUME",
                               "value": volume.map { $0 == 0 ? "Muted" : "\($0)" } ?? "—",
                               "indicator": ["value": volume ?? 0]])
        case "dial.seek":
            var payload: [String: Any] = [
                "title": short(s["title"] as? String ?? "Nothing playing", 20),
                "value": duration > 0 ? "\(clock(position)) / \(clock(duration))" : "—",
                "indicator": ["value": duration > 0 ? Int(min(1, max(0, position / duration)) * 100) : 0]]
            if let artworkURL { payload["icon"] = artworkURL }
            feedback(context, payload)
        case "logic.mixer":
            let name = settings[context]?["name"] as? String
            feedback(context, ["title": name ?? "Pick a control",
                               "value": name == nil ? "in settings" : (lastMove[context] ?? "—")])
        case "midi.dial":
            let settings = self.settings[context] ?? [:]
            let label = settings["label"] as? String ?? settings["name"] as? String
            let absolute = (settings["mode"] as? String) == "absolute"
            feedback(context, ["title": label ?? "Set it up",
                               "value": label == nil ? "in settings"
                                   : (absolute ? "\((settings["value"] as? NSNumber)?.intValue ?? 64)"
                                               : (lastMove[context] ?? "—"))])
        case "midi.key":
            title(context, settings[context]?["label"] as? String ?? "Set it\nup")

        case "logic.mute":
            let name = settings[context]?["name"] as? String
            // "Mic 1 · Mute" reads as "Mic 1" on a key that already shows a
            // crossed-out mic.
            title(context, name.map { $0.components(separatedBy: " · ").first ?? $0 } ?? "Pick a\nmic")

        case "dial.font":
            let size = (s["fontSize"] as? NSNumber)?.doubleValue ?? 42
            feedback(context, ["title": "LYRIC SIZE",
                               "value": "\(Int(size)) pt",
                               "indicator": ["value": Int((size - 24) / 72 * 100)]])
        default:
            break
        }
    }

    private func title(_ context: String, _ text: String) {
        sendOnce(context, "title", ["event": "setTitle", "context": context,
                                    "payload": ["title": text, "target": 0]])
    }

    private func image(_ context: String, _ dataURL: String?) {
        var payload: [String: Any] = ["target": 0]
        if let dataURL { payload["image"] = dataURL }   // absent = the manifest's image
        sendOnce(context, "image", ["event": "setImage", "context": context, "payload": payload])
    }

    private func setState(_ context: String, _ value: Int) {
        sendOnce(context, "state", ["event": "setState", "context": context, "payload": ["state": value]])
    }

    private func feedback(_ context: String, _ payload: [String: Any]) {
        sendOnce(context, "feedback", ["event": "setFeedback", "context": context, "payload": payload])
    }

    private func forget(_ context: String) {
        lastSent = lastSent.filter { !$0.key.hasPrefix(context + "|") }
    }

    /// Skips a message identical to the last one of its kind for that context.
    /// A poll twice a second would otherwise redraw every key twice a second.
    private func sendOnce(_ context: String, _ kind: String, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8) else { return }
        let slot = context + "|" + kind
        guard lastSent[slot] != text else { return }
        lastSent[slot] = text
        socket.send(.string(text)) { _ in }
    }

    private func short(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Keys

enum Keys {
    /// Same reading of a key name as Studio One's: "F♯m", "Gb", "A#m".
    static func root(_ key: String) -> Int? {
        var text = key.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower.hasSuffix("m") && !lower.hasSuffix("maj") { text.removeLast() }
        let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let head = text.first, var index = naturals[Character(head.uppercased())] else { return nil }
        let rest = text.dropFirst()
        if rest.hasPrefix("♯") || rest.hasPrefix("#") { index += 1 }
        if rest.hasPrefix("♭") || rest.hasPrefix("b") { index -= 1 }
        return (index % 12 + 12) % 12
    }

    /// Semitones from the detected key to the one in use, folded into −6…+6.
    static func shift(from detected: String?, to current: String?) -> Int? {
        guard let detected, let current, let a = root(detected), let b = root(current) else { return nil }
        let raw = ((b - a) % 12 + 12) % 12
        return raw > 6 ? raw - 12 : raw
    }
}

let deck = Deck()
deck.connect()
RunLoop.main.run()
