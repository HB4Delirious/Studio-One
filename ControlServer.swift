import AppKit
import Network

extension Notification.Name {
    /// Asks the Controls window to open the lyrics window — only a view can.
    static let showLyricsWindow = Notification.Name("StudioOne.showLyricsWindow")
}

/// The Stream Deck plug-in's way in: always on, on 127.0.0.1 only, and only
/// for requests carrying the token.
///
/// The token matters even on loopback — any web page can send requests to
/// 127.0.0.1 — and since it travels in a custom header, which a cross-site
/// request can't carry without a preflight this server never answers, a page
/// can't drive playback. The port and token are in a file only this user can
/// read, where the plug-in finds them.
@MainActor
final class ControlServer {

    static let shared = ControlServer()

    /// Above the request line (8710–8719) and the Spotify sign-in (8725).
    static let ports: ClosedRange<UInt16> = 8730...8739

    static var infoURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio One", isDirectory: true)
            .appendingPathComponent("control.json")
    }

    private(set) var port: UInt16?
    private var listener: NWListener?
    private var midiListener: NWListener?
    private(set) var midiPort: UInt16?
    private weak var model: KaraokeModel?
    private let queue = DispatchQueue(label: "com.logan.SpotifyKaraoke.control")
    private lazy var token: String = existingToken() ?? Self.makeToken()

    /// Cached and refreshed in the background: the deck polls twice a second,
    /// and each read is an Apple Event.
    private var volume: Int?
    private var volumeFetchedAt = Date.distantPast
    private var mutedFrom: Int?

    private var artwork: (track: String, data: Data)?

    func start(model: KaraokeModel) {
        self.model = model
        guard listener == nil, !starting else { return }
        starting = true
        Task { [weak self] in
            guard let self else { return }
            let opened = await PortListener.open(
                ports: Self.ports,
                parameters: { port in
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                                 port: NWEndpoint.Port(rawValue: port)!)
                    return parameters
                },
                queue: queue,
                configure: { listener in
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in self?.accept(connection) }
                    }
                })
            guard let (listener, port) = opened else {
                starting = false
                Diagnostics.log("stream deck: no free control port in \(Self.ports)")
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    Task { @MainActor in
                        guard let self, self.listener === listener else { return }
                        self.listener = nil
                        self.port = nil
                        Diagnostics.log("stream deck: control port failed — reopening")
                        self.start(model: model)
                    }
                }
            }
            self.listener = listener
            self.port = port
            await startMIDILane()
            starting = false
            writeInfo()
            Diagnostics.log("stream deck: control port \(port)")
        }
    }

    private var starting = false

    // MARK: - MIDI lane

    /// A datagram port for the dials' ticks: no connection, no reply, and put
    /// on the MIDI port from the network thread as it lands — under 1 ms,
    /// where an HTTP request per tick could take 40.
    ///
    /// A datagram is the token, a newline, a controller message's three bytes,
    /// then an optional label for "Last sent".
    private func startMIDILane() async {
        guard midiListener == nil else { return }
        let token = Data(self.token.utf8)
        let laneQueue = DispatchQueue(label: "com.logan.SpotifyKaraoke.midi-lane", qos: .userInteractive)
        let opened = await PortListener.open(
            ports: Self.midiPorts,
            parameters: { port in
                let parameters = NWParameters.udp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                             port: NWEndpoint.Port(rawValue: port)!)
                return parameters
            },
            queue: laneQueue,
            configure: { listener in
                listener.newConnectionHandler = { connection in
                    connection.start(queue: laneQueue)
                    Self.receiveTicks(on: connection, token: token)
                }
            })
        guard let (listener, port) = opened else {
            Diagnostics.log("stream deck: no free MIDI lane port — dials use the control port")
            return
        }
        midiListener = listener
        midiPort = port
        Diagnostics.log("stream deck: MIDI lane \(port)")
    }

    /// Clear of the control port range, the request line and the sign-in.
    static let midiPorts: ClosedRange<UInt16> = 8740...8749

    nonisolated private static func receiveTicks(on connection: NWConnection, token: Data) {
        connection.receiveMessage { data, _, _, error in
            if let data, let (bytes, label) = parseTick(data, token: token) {
                MIDIBridge.sendNow(bytes, label: label)
            }
            if error == nil { receiveTicks(on: connection, token: token) } else { connection.cancel() }
        }
    }

    nonisolated static func parseTick(_ data: Data, token: Data) -> ([UInt8], String)? {
        let bytes = [UInt8](data)
        guard bytes.count >= token.count + 4,
              Data(bytes[0..<token.count]) == token,
              bytes[token.count] == 0x0A else { return nil }
        let message = Array(bytes[(token.count + 1)...(token.count + 3)])
        guard message[0] & 0xF0 == 0xB0, message[1] < 128, message[2] < 128 else { return nil }
        let label = String(decoding: bytes[(token.count + 4)...], as: UTF8.self)
        return (message, label.isEmpty ? "MIDI" : label)
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        LocalHTTP.receive(on: connection, limit: 65_536) { [weak self] request in
            Task { @MainActor in await self?.respond(to: request, on: connection) }
        }
    }

    private func respond(to request: LocalHTTP.Request, on connection: NWConnection) async {
        guard request.headers["x-studio-one-token"] == token else {
            return send(401, json: ["error": "bad token"], on: connection)
        }
        switch (request.method, request.path) {
        case ("GET", "/controls"):
            // What the dials can be pointed at, with the channel, so the deck
            // can send the same messages itself while this app is closed.
            send(200, json: ["channel": Int(MixerControl.channel) + 1,
                             "step": MixerControl.step.rawValue,
                             "controls": MixerControl.all.map {
                ["id": $0.id, "name": $0.name, "cc": Int($0.cc), "kind": $0.kind.rawValue,
                 "mic": $0.mic, "channel": Int(MixerControl.channel) + 1]
            }], on: connection)
        case ("GET", "/state"):
            send(200, json: state(), on: connection)
        case ("GET", "/artwork"):
            if let data = await currentArtwork() {
                send(200, type: "image/png", body: data, on: connection)
            } else {
                send(404, json: ["error": "no artwork"], on: connection)
            }
        case ("POST", "/command"):
            let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let command = object["command"] as? String ?? ""
            let result = await perform(command, object)
            send(result == nil ? 200 : 400,
                 json: result.map { ["error": $0] } ?? ["ok": true, "state": state()],
                 on: connection)
        default:
            send(404, json: ["error": "not found"], on: connection)
        }
    }

    private func send(_ status: Int, json: [String: Any], on connection: NWConnection) {
        LocalHTTP.respond(status, json: json, on: connection)
    }

    private func send(_ status: Int, type: String, body: Data, on connection: NWConnection) {
        LocalHTTP.respond(status, type: type, body: body, on: connection)
    }

    // MARK: - State

    private func state() -> [String: Any] {
        guard let model else { return ["running": false] }
        refreshVolumeIfStale()
        let shown = model.publishedAnalysis
        var state: [String: Any] = [
            "running": true,
            "source": model.musicSource == .spotify ? "spotify" : "appleMusic",
            "sourceName": model.musicSource.displayName,
            "connected": model.connection == .ready,
            "playing": model.isPlaying,
            "position": model.playbackPosition,
            "lyricOffsetMs": model.offsetMilliseconds,
            "fontSize": LyricSize.current,
            "tempoMultiplier": model.tempoMultiplier,
            "keyIsManual": model.manualKey != nil,
            "tempoIsManual": model.manualTempo != nil,
            "lyrics": Self.name(of: model.lyricsState),
            "midiEnabled": UserDefaults.standard.bool(forKey: MIDIBridge.enabledKey),
            "lastSent": MIDIBridge.shared.lastSent,
        ]
        if let track = model.track {
            state["title"] = track.name
            state["artist"] = track.artist
            state["duration"] = track.duration
            state["trackID"] = track.uri
        }
        if let key = shown?.key { state["key"] = key }
        if let key = model.analysis?.key { state["detectedKey"] = key }
        if let tempo = shown?.tempo { state["bpm"] = tempo }
        if let volume { state["volume"] = volume }
        return state
    }

    private static func name(of state: LyricsState) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .synced: return "synced"
        case .plain: return "plain"
        case .instrumental: return "instrumental"
        case .missing: return "missing"
        }
    }

    private func refreshVolumeIfStale() {
        guard Date().timeIntervalSince(volumeFetchedAt) > 2, let browser = model?.browser else { return }
        volumeFetchedAt = Date()
        Task { @MainActor in self.volume = await browser.volume() }
    }

    // MARK: - Commands

    /// Nil on success, or why not.
    private func perform(_ command: String, _ object: [String: Any]) async -> String? {
        guard let model else { return "not ready" }
        let amount = (object["amount"] as? NSNumber)?.doubleValue ?? 0
        let amountControl = object["control"] as? String
        switch command {
        case "playPause":    model.togglePlayback()
        case "next":         model.nextTrack()
        case "previous":     model.previousTrack()
        case "fadeOut":      model.fadeOut()
        case "seekBy":
            let length = model.track?.duration ?? 0
            model.seek(to: min(max(0, model.playbackPosition + amount), max(0, length - 1)))

        case "keyBy":        model.nudgeKey(by: Int(amount))
        case "keyReset":     model.manualKey = nil
        case "tempoBy":      model.nudgeTempo(by: amount)
        case "tempoReset":
            model.manualTempo = nil
            model.tempoMultiplier = 1
        case "tempoDouble":  model.tempoMultiplier = min(4, model.tempoMultiplier * 2)
        case "tempoHalf":    model.tempoMultiplier = max(0.25, model.tempoMultiplier / 2)

        case "lyricsBy":     model.offsetMilliseconds += amount
        case "lyricsReset":  model.offsetMilliseconds = 0
        case "reloadLyrics": model.reloadLyrics()
        case "syncNow":      model.syncToLineNow()

        case "fontBy":
            UserDefaults.standard.set(LyricSize.clamped(LyricSize.current + amount), forKey: LyricSize.key)
        case "fontReset":
            UserDefaults.standard.set(LyricSize.standard, forKey: LyricSize.key)

        case "volumeBy", "volumeMute":
            guard let browser = model.browser else { return "no volume on this source" }
            let current: Int
            if let volume { current = volume } else { current = await browser.volume() }
            let target: Int
            if command == "volumeMute" {
                if current == 0, let previous = mutedFrom { target = previous; mutedFrom = nil }
                else { mutedFrom = current; target = 0 }
            } else {
                target = min(100, max(0, current + Int(amount)))
            }
            // Recorded before the wait: the next tick of a fast dial arrives
            // while this one is still with the player.
            volume = target
            volumeFetchedAt = Date()
            await browser.setVolume(target)

        case "showLyrics":
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .showLyricsWindow, object: nil)
        case "lyricsFullScreen":
            NSApp.activate(ignoringOtherApps: true)
            if let window = Self.lyricsWindow {
                window.toggleFullScreen(nil)
            } else {
                // Not open yet: open it, then give it a moment to exist.
                NotificationCenter.default.post(name: .showLyricsWindow, object: nil)
                try? await Task.sleep(nanoseconds: 600_000_000)
                Self.lyricsWindow?.toggleFullScreen(nil)
            }

        case "sendKey":
            guard UserDefaults.standard.bool(forKey: MIDIBridge.enabledKey) else {
                return "MIDI to Logic is off in Settings"
            }
            model.publishToLogic()

        case "mixerBy":
            guard let control = MixerControl.named((amountControl ?? "")), control.kind == .dial else {
                return "no such dial"
            }
            MIDIBridge.shared.sendMixer(control, ticks: Int(amount))

        case "mixerToggle":
            guard let control = MixerControl.named((amountControl ?? "")) else { return "no such control" }
            MIDIBridge.shared.sendMixerToggle(control)

        case "midi":
            guard let cc = (object["cc"] as? NSNumber)?.intValue, (0...127).contains(cc),
                  let value = (object["value"] as? NSNumber)?.intValue, (0...127).contains(value),
                  let channel = (object["channel"] as? NSNumber)?.intValue, (1...16).contains(channel) else {
                return "midi needs cc and value 0–127 and channel 1–16"
            }
            MIDIBridge.shared.sendRaw(cc: UInt8(cc), value: UInt8(value),
                                      channel: UInt8(channel - 1),
                                      label: object["label"] as? String)

        case "toggleSource":
            model.changeSource(to: model.musicSource == .spotify ? .appleMusic : .spotify)

        default:
            return "unknown command \(command)"
        }
        return nil
    }

    private static var lyricsWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Lyrics" && $0.isVisible }
    }

    // MARK: - Artwork

    /// A 144 px PNG — a key's full resolution — cached per song.
    private func currentArtwork() async -> Data? {
        guard let model, let track = model.track else { return nil }
        if let artwork, artwork.track == track.uri { return artwork.data }
        guard let png = await model.coverImage()?.squarePNG(side: 144),
              model.track?.uri == track.uri else { return nil }
        artwork = (track.uri, png)
        return png
    }

    // MARK: - Token file

    private func writeInfo() {
        guard let port else { return }
        let url = Self.infoURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var info: [String: Any] = ["port": Int(port), "token": token]
        if let midiPort { info["midiPort"] = Int(midiPort) }
        guard let data = try? JSONSerialization.data(withJSONObject: info) else { return }
        // Owner only: the token is what keeps others off the port.
        FileManager.default.createFile(atPath: url.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Kept across launches, so a plug-in that read it once keeps working.
    private func existingToken() -> String? {
        guard let data = try? Data(contentsOf: Self.infoURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, token.count >= 32 else { return nil }
        return token
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
