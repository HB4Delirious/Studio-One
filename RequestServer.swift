import AppKit
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI

/// The request line: guests on the same Wi-Fi scan a QR code, search the
/// host's Apple Music library — its scripting can't reach the catalogue — and
/// their picks land in a real playlist, "Studio One Requests", which is what
/// gives Up Next the queue. A second code is the host's own remote. It serves
/// only while switched on.
@MainActor
final class RequestServer: ObservableObject {

    static let shared = RequestServer()

    /// Guests can follow the lyrics on their phones (on unless turned off).
    static let guestLyricsKey = "guestLyrics"
    static var guestLyrics: Bool { UserDefaults.standard.object(forKey: guestLyricsKey) as? Bool ?? true }

    /// Returning guests see the songs they've sung before (on unless off).
    static let guestHistoryKey = "guestHistory"
    static var guestHistory: Bool { UserDefaults.standard.object(forKey: guestHistoryKey) as? Bool ?? true }

    /// The request line is on: the port is open and guests' code works.
    @Published private(set) var running = false
    /// The Studio One Remote app (and the web remote) can reach this Mac.
    @Published private(set) var remoteListening = false

    /// The iPhone app: on, the port stays open and is advertised over
    /// Bonjour whether or not the request line is.
    static let iPhoneRemoteKey = "iPhoneRemote"
    static var iPhoneRemote: Bool { UserDefaults.standard.bool(forKey: iPhoneRemoteKey) }
    /// Kept, so a paired phone keeps working: reset from Settings.
    static let remoteTokenKey = "remoteToken"
    /// This Mac's install, in the Bonjour record, for a paired phone to find
    /// it again when its address changes. Not a secret.
    static let installIDKey = "installID"
    static let serviceType = "_studioone._tcp"

    /// Two tokens: the guest code is shown to the room; the remote code can
    /// skip, seek and start songs, and isn't.
    @Published private(set) var guestAddress: URL?
    @Published private(set) var remoteAddress: URL?
    @Published private(set) var failure: String?
    @Published private(set) var received: [String] = []

    private var listener: NWListener?
    private var host: String?
    private var port: UInt16?
    private weak var model: KaraokeModel?
    private var guestToken = ""
    private var remoteToken = ""
    private var guestWanted = false
    private var remoteWanted = false

    /// Apple Music's requests playlist, for guests; nil with Spotify.
    private var library: RequestQueue? { model?.requestQueue }
    /// Either player's library: the queue, search, volume.
    private var browser: MusicBrowser? { model?.browser }

    /// Up Next and the cover each cost an Apple Event and the remote polls
    /// every two seconds, so both are kept until the song changes.
    private var cachedQueue: [LibraryTrack] = []

    /// Who asked for what, by title and artist — the one handle Up Next and
    /// the playing song share. The latest request wins.
    private var requestedBy: [String: String] = [:]

    static func songKey(_ name: String, _ artist: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces) + "|"
            + artist.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// The guest who requested a song, if one did.
    func requester(name: String, artist: String) -> String? {
        requestedBy[Self.songKey(name, artist)]
    }
    private var cachedArtwork: Data?
    private var cachedEditable = false
    /// The playing song's cover for guests' phones, small, kept per song.
    private var guestArt: (uri: String, data: Data)?
    /// A guest's past songs, by folded name: each read is every night's file
    /// and an Apple Event, and a phone asks on every visit.
    private var historyCache: [String: (at: Date, data: Data)] = [:]
    /// The song the queue was last read for; emptied when a request or a
    /// reorder changes it.
    private var queueKey = ""
    /// The song the remote's cover and edit rights were read for — kept apart
    /// from `queueKey`, which guest pages refresh too.
    private var coverKey = ""
    /// Tracked locally between occasional reads, rather than an Apple Event
    /// per poll.
    private var cachedVolume: Int?
    private var volumeReadAt = Date.distantPast

    /// In the path, so something that merely shares the Wi-Fi can't wander in
    /// by finding the port. Not a password: anyone shown the code can request.
    private static func makeToken(length: Int = 8) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// The remote's code, made once and kept. Longer than the guests': it
    /// lasts, and it can do more.
    private static func storedRemoteToken() -> String {
        if let saved = UserDefaults.standard.string(forKey: remoteTokenKey), saved.count >= 16 { return saved }
        let token = makeToken(length: 16)
        UserDefaults.standard.set(token, forKey: remoteTokenKey)
        return token
    }

    static var installID: String {
        if let saved = UserDefaults.standard.string(forKey: installIDKey) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: installIDKey)
        return id
    }

    /// The remote's address with this Mac's ID after the "#", for the app to
    /// pair with; a phone's camera opens the web remote, which ignores it.
    var pairingAddress: URL? {
        remoteAddress.flatMap { URL(string: $0.absoluteString + "#studioone=" + Self.installID) }
    }

    /// Between asking for the port and its answering.
    private var starting = false
    private var attempt = 0

    /// The request line, for guests: Apple Music only.
    func start(model: KaraokeModel) {
        guard !running, !guestWanted else { return }
        guard model.requestQueue != nil else {
            failure = "Requests need a library to search. Switch to Apple Music."
            return
        }
        self.model = model
        guestToken = Self.makeToken()
        guestWanted = true
        failure = nil
        openListener()
    }

    /// With a reason, shown where the codes were.
    func stop(because reason: String) {
        stop()
        failure = reason
    }

    /// The request line off. The port stays open if the remote app wants it.
    func stop() {
        guestWanted = false
        guestToken = ""
        running = false
        guestAddress = nil
        if remoteWanted {
            Diagnostics.log("requests: stopped; the remote stays on")
        } else {
            closeListener()
            Diagnostics.log("requests: stopped")
        }
    }

    /// At launch and from Settings: the remote app on or off, as set.
    func configureRemote(model: KaraokeModel) {
        self.model = model
        let wanted = Self.iPhoneRemote
        guard wanted != remoteWanted else { return }
        remoteWanted = wanted
        if wanted {
            openListener()
            advertise()
        } else if guestWanted {
            advertise()
        } else {
            closeListener()
        }
    }

    /// A new code: phones paired with the old one need pairing again.
    func resetRemoteCode() {
        UserDefaults.standard.removeObject(forKey: Self.remoteTokenKey)
        remoteToken = Self.storedRemoteToken()
        publishAddresses()
        Diagnostics.log("requests: remote code reset")
    }

    /// The first free port of ten, rather than one that may be taken; if
    /// it's open already, only the addresses change.
    private func openListener() {
        remoteToken = Self.storedRemoteToken()
        if listener != nil { return publishAddresses() }
        guard !starting else { return }
        guard let host = Self.localAddress() else {
            failure = "No Wi-Fi address — the Mac has to be on the same network as your phones."
            guestWanted = false
            return
        }
        starting = true
        attempt += 1
        let thisAttempt = attempt
        let service = remoteWanted ? Self.service : nil
        Task { [weak self] in
            guard let self else { return }
            let opened = await PortListener.open(
                ports: 8710...8719,
                parameters: { _ in
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    return parameters
                },
                queue: .global(qos: .userInitiated),
                configure: { listener in
                    listener.service = service
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in self?.accept(connection) }
                    }
                })
            // Stopped while the port was being found: let it go.
            guard thisAttempt == attempt else { opened?.listener.cancel(); return }
            starting = false
            guard let (listener, port) = opened else {
                failure = "Couldn't open a port in 8710–8719."
                guestWanted = false
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    if case .failed(let error) = state {
                        self.closeListener()
                        self.guestWanted = false
                        self.failure = error.localizedDescription
                    }
                }
            }
            self.listener = listener
            self.host = host
            self.port = port
            // Wanted or not while the port was being found.
            advertise()
            publishAddresses()
            Diagnostics.log("requests: listening on \(host):\(port)\(remoteWanted ? ", advertised for the remote app" : "")")
        }
    }

    private func closeListener() {
        attempt += 1
        starting = false
        listener?.cancel()
        listener = nil
        running = false
        remoteListening = false
        guestAddress = nil
        remoteAddress = nil
    }

    private func publishAddresses() {
        guard listener != nil, let host, let port else { return }
        running = guestWanted
        guestAddress = guestWanted ? URL(string: "http://\(host):\(port)/s/\(guestToken)") : nil
        remoteAddress = URL(string: "http://\(host):\(port)/r/\(remoteToken)")
        remoteListening = true
    }

    /// The remote app finds the Mac by Bonjour, so a new address after a
    /// router restart doesn't need pairing again. Only while it's wanted.
    private func advertise() {
        listener?.service = remoteWanted ? Self.service : nil
    }

    private static var service: NWListener.Service {
        let record = NWTXTRecord(["id": installID, "v": "1"])
        return NWListener.Service(name: Host.current().localizedName ?? "Studio One", type: serviceType,
                                  domain: nil, txtRecord: record)
    }

    /// The Mac's address on the local network: Wi-Fi, else wired.
    private static func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [String: String] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard pointer.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointer.pointee.ifa_addr,
                              socklen_t(pointer.pointee.ifa_addr.pointee.sa_len),
                              &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: buffer)
            // Self-assigned when no network answered; reaches nobody.
            guard !address.hasPrefix("169.254.") else { continue }
            candidates[name] = address
        }
        return candidates["en0"] ?? candidates["en1"] ?? candidates.values.sorted().first
    }

    // MARK: - Connections

    /// Nothing sent here is bigger than a song request.
    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        LocalHTTP.receive(on: connection, limit: 32 * 1024) { [weak self] request in
            Task { @MainActor in await self?.respond(to: request, on: connection) }
        }
    }

    private func respond(to request: LocalHTTP.Request, on connection: NWConnection) async {
        let method = request.method, target = request.path, body = request.body
        let guestRoot = "/s/\(guestToken)"
        let remoteRoot = "/r/\(remoteToken)"

        if !remoteToken.isEmpty, target.hasPrefix(remoteRoot) {
            return await remote(String(target.dropFirst(remoteRoot.count)),
                                method: method, body: body, on: connection)
        }
        // Only while the request line is on: off, the guests' code is empty.
        guard guestWanted, !guestToken.isEmpty, target.hasPrefix(guestRoot) else {
            // Wrong or missing token: say nothing useful.
            return send(404, "text/plain", Data("not found".utf8), on: connection)
        }
        let route = String(target.dropFirst(guestRoot.count))

        if method == "GET", route.isEmpty || route == "/" {
            return send(200, "text/html; charset=utf-8",
                        Data(RequestPages.guest(code: guestToken, lyrics: Self.guestLyrics).utf8), on: connection)
        }
        if method == "GET", route.hasPrefix("/p/") {
            return performance(String(route.dropFirst(3)), range: request.headers["range"], on: connection)
        }

        if method == "GET", route.hasPrefix("/api/icon") {
            guard let icon = Self.appIcon else {
                return send(404, "text/plain", Data(), on: connection)
            }
            return send(200, "image/png", icon, on: connection)
        }

        if method == "GET", route.hasPrefix("/api/search") {
            return send(200, "application/json", await searchJSON(route), on: connection)
        }

        if method == "GET", route.hasPrefix("/api/mine") {
            return send(200, "application/json", await mineJSON(route), on: connection)
        }

        if method == "GET", route.hasPrefix("/api/playing") {
            return send(200, "application/json", playingJSON(), on: connection)
        }

        if method == "GET", route.hasPrefix("/api/art") {
            guard let data = await guestArtwork() else {
                return send(404, "text/plain", Data(), on: connection)
            }
            return send(200, "image/jpeg", data, on: connection)
        }

        if method == "GET", route.hasPrefix("/api/history") {
            return send(200, "application/json", await historyJSON(route), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/add") {
            return await add(body: body, on: connection)
        }

        if method == "GET", route.hasPrefix("/api/now"), Self.guestLyrics {
            return send(200, "application/json", nowJSON(), on: connection)
        }

        if method == "GET", route.hasPrefix("/api/lyrics"), Self.guestLyrics {
            return send(200, "application/json", lyricsJSON(), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/guess") {
            return guess(body: body, on: connection)
        }

        send(404, "text/plain", Data("not found".utf8), on: connection)
    }

    /// Name that tune: a guest's guess, judged.
    /// A recording: its page (/p/<id>), its audio (/audio, or
    /// /audio?download=1 to save it) and its photo (/photo).
    private func performance(_ rest: String, range: String?, on connection: NWConnection) {
        let path = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rest
        let parts = path.split(separator: "/").map(String.init)
        let performances = Performances.shared
        guard let id = parts.first, let recording = performances.recording(id: id) else {
            return send(404, "text/html; charset=utf-8", Data(RequestPages.recordingGone.utf8), on: connection)
        }
        let base = "/s/\(guestToken)/p/\(recording.id)"
        switch parts.count > 1 ? parts[1] : "" {
        case "":
            let page = RequestPages.performance(recording, base: base,
                                                venue: VenueThemes.shared.current.venueName,
                                                expires: Performances.expiry(of: recording))
            send(200, "text/html; charset=utf-8", Data(page.utf8), on: connection)
        case "audio":
            LocalHTTP.respondFile(performances.audioURL(recording), type: "audio/mp4", range: range,
                                  download: rest.contains("download=1") ? "\(recording.name).m4a" : nil,
                                  on: connection)
        case "photo" where recording.hasPhoto:
            LocalHTTP.respondFile(performances.photoURL(recording), type: "image/jpeg", range: nil, on: connection)
        default:
            send(404, "text/plain", Data("not found".utf8), on: connection)
        }
    }

    private func guess(body: Data, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = object["guess"] as? String, PartyGames.shared.tune != nil else {
            return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
        }
        let nick = (object["nick"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)
        let (correct, winner) = PartyGames.shared.guess(String(text.prefix(120)), from: String(nick))
        var json: [String: Any] = ["ok": true, "correct": correct]
        if let winner { json["winner"] = winner }
        send(200, "application/json", (try? JSONSerialization.data(withJSONObject: json)) ?? Data(), on: connection)
    }

    /// The game under way, for phones: Name that tune's question or result.
    private func gameJSON(for track: PlayerTrack) -> [String: Any]? {
        guard let tune = PartyGames.shared.tune, tune.uri == track.uri else { return nil }
        var game: [String: Any] = ["kind": "tune", "open": !tune.revealed, "guesses": tune.guesses]
        if let winner = tune.winner { game["winner"] = winner }
        if tune.revealed { game["answer"] = "\(tune.answer) — \(tune.artist)" }
        return game
    }

    /// Where the song is, for a phone following the lyrics: polled about once
    /// a second and run on between polls. The lyrics' own position — sync
    /// trim and the output's latency included — so phones match the screen.
    private func nowJSON() -> Data {
        guard let model else { return Data("{}".utf8) }
        var state: [String: Any] = [
            "uri": model.track?.uri ?? "",
            "pos": model.lyricPosition,
            "playing": model.isPlaying,
            // Changes whenever the lyrics do, for the same song too — and as a
            // game hides or shows them.
            "rev": "\(model.lyricsRevision)-\(PartyGames.shared.finishURI ?? "")-\(PartyGames.shared.tune.map { $0.revealed ? "shown" : "hidden" } ?? "")",
        ]
        if model.intermission != nil {
            let next = model.nextUp
            state["break"] = [
                "name": next?.name ?? "",
                "artist": next?.artist ?? "",
                "singer": next.flatMap { requester(name: $0.name, artist: $0.artist) } ?? "",
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
    }

    /// The playing song's lyrics, line by line with their times and duet
    /// parts — fetched once a song.
    private func lyricsJSON() -> Data {
        guard let model, let track = model.track else { return Data("{}".utf8) }
        var json: [String: Any] = ["uri": track.uri, "name": track.name, "artist": track.artist]
        // House music has no one singing along.
        if model.fillerPlaying { json["lines"] = []; json["plain"] = "House music — back to the singing soon."
            return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8) }
        // Name that tune: nothing that gives it away.
        if let tune = PartyGames.shared.tune, tune.uri == track.uri, !tune.revealed {
            json = ["uri": track.uri, "name": "???", "artist": "", "lines": [],
                    "plain": "Name that tune! The words come back once someone's guessed it."]
            return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        }
        json["lines"] = model.lines.map { line -> [String: Any] in
            var row: [String: Any] = ["t": line.time, "x": line.text, "p": line.part?.rawValue ?? 0]
            // Finish the lyric: blanks until the line's been sung.
            if track.uri == PartyGames.shared.finishURI, let from = PartyGames.shared.finishMasks[line.id] {
                row["mx"] = PartyGames.masked(line, from: from)
                row["v"] = line.voicedEnd
            }
            return row
        }
        if case .plain(let text) = model.lyricsState { json["plain"] = text }
        // Still being looked up: the phone waits for the revision to move.
        if model.lyricsState == .loading { json["loading"] = true }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }

    /// The remote: everything the guest page can do, plus the transport.
    private func remote(_ route: String, method: String, body: Data,
                        on connection: NWConnection) async {
        if method == "GET", route.isEmpty || route == "/" {
            return send(200, "text/html; charset=utf-8", Data(RequestPages.remote.utf8), on: connection)
        }

        if method == "GET", route.hasPrefix("/api/state") {
            return send(200, "application/json", await stateJSON(), on: connection)
        }

        if method == "GET", route.hasPrefix("/api/artwork") {
            guard let data = cachedArtwork else {
                return send(404, "text/plain", Data(), on: connection)
            }
            return send(200, "image/jpeg", data, on: connection)
        }

        if method == "GET", route.hasPrefix("/api/search") {
            return send(200, "application/json", await remoteSearchJSON(route), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/command") {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let command = object["cmd"] as? String, let model else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            switch command {
            case "playpause": model.togglePlayback()
            case "next":      model.nextTrack()
            case "prev":      model.previousTrack()
            case "fade":      model.fadeOut()
            case "seek":      if let to = object["to"] as? Double { model.seek(to: to) }
            default:          break
            }
            return send(200, "application/json", Data(#"{"ok":true}"#.utf8), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/play") {
            // Apple Music by its database ID; Spotify by URI.
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            if let id = object["id"] as? Int, let library {
                await model?.leaveHouseMusic()
                try? await library.playNow(databaseID: id)
            } else if let uri = object["uri"] as? String, let browser {
                await model?.leaveHouseMusic()
                try? await browser.play(LibraryTrack(id: uri, name: "", artist: "", duration: 0,
                                                     playlistIndex: nil, trackIndex: nil, uri: uri))
            } else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            return send(200, "application/json", Data(#"{"ok":true}"#.utf8), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/volume") {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let value = object["value"] as? Int, let browser else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            let level = min(100, max(0, value))
            cachedVolume = level
            volumeReadAt = Date()
            await browser.setVolume(level)
            return send(200, "application/json", Data(#"{"ok":true}"#.utf8), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/nudge") {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let what = object["what"] as? String, let model else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            let by = object["by"] as? Int ?? 0
            switch what {
            case "key":   model.nudgeKey(by: by)
            case "tempo": model.nudgeTempo(by: Double(by))
            case "reset": model.clearNudges()
            default:      break
            }
            return send(200, "application/json", Data(#"{"ok":true}"#.utf8), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/reorder") {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let from = object["from"] as? Int, let to = object["to"] as? Int,
                  let library, cachedEditable else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            do { try await library.reorderQueue(from: from, to: to) }
            catch { Diagnostics.log("ERROR reorder: \(error.localizedDescription)") }
            queueKey = ""                       // force a re-read on the next poll
            model?.refreshNextUp()
            return send(200, "application/json", Data(#"{"ok":true}"#.utf8), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/add") {
            return await add(body: body, on: connection)
        }

        send(404, "text/plain", Data("not found".utf8), on: connection)
    }

    private func stateJSON() async -> Data {
        var state: [String: Any] = [:]
        guard let model else { return Data("{}".utf8) }
        state["playing"] = model.isPlaying
        state["position"] = model.playbackPosition
        // When the position was read, for a phone to run the clock itself.
        state["at"] = Date().timeIntervalSince1970
        state["source"] = model.musicSource.rawValue
        state["canRequest"] = library != nil
        state["house"] = model.fillerPlaying
        if let pause = model.intermission {
            state["intermission"] = true
            if let ends = pause.endsAt { state["breakEnds"] = ends.timeIntervalSince1970 }
        }
        if let next = model.nextUp {
            var row: [String: Any] = ["name": next.name, "artist": next.artist]
            if let singer = requester(name: next.name, artist: next.artist) { row["singer"] = singer }
            state["next"] = row
        }

        if let track = model.track {
            state["name"] = track.name
            state["artist"] = track.artist
            state["duration"] = track.duration
            state["artKey"] = track.uri
            if let singer = requester(name: track.name, artist: track.artist) { state["singer"] = singer }

            // One Apple Event per track change, not one per poll.
            if queueKey != track.uri {
                queueKey = track.uri
                await refreshQueue()
            }
            if coverKey != track.uri {
                coverKey = track.uri
                cachedEditable = await library?.queueIsEditable() ?? false
                // Music's own is ~570 KB, a lot for party Wi-Fi.
                cachedArtwork = await model.coverImage()?.squareJPEG(side: 600, quality: 0.75)
            }
        }

        state["corrected"] = model.hasManualValues
        if let analysis = model.publishedAnalysis {
            state["key"] = analysis.key ?? ""
            state["tempo"] = analysis.tempo.map { Int($0.rounded()) } ?? 0
        }

        state["queue"] = cachedQueue.dropFirst().map {
            ["name": $0.name, "artist": $0.artist]
        }
        state["queueEditable"] = cachedEditable
        // Re-read now and then: Music and the Stream Deck change it too.
        if cachedVolume == nil || Date().timeIntervalSince(volumeReadAt) > 10 {
            cachedVolume = await browser?.volume() ?? cachedVolume
            volumeReadAt = Date()
        }
        state["volume"] = cachedVolume ?? 100
        return (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
    }

    private func refreshQueue() async {
        cachedQueue = (try? await browser?.upNext(limit: 30))??.tracks ?? []
    }

    /// A guest's own requests and where each stands in Up Next: 0 is singing
    /// now, 1 next.
    private func mineJSON(_ route: String) async -> Data {
        let nick = (Self.queryValue("nick", in: route)?
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? "").trimmingCharacters(in: .whitespaces)
        guard !nick.isEmpty else { return Data("[]".utf8) }
        let key = model?.track?.uri ?? ""
        if queueKey != key {
            queueKey = key
            await refreshQueue()
        }
        var mine = cachedQueue.enumerated().compactMap { index, track -> [String: Any]? in
            guard requester(name: track.name, artist: track.artist) == nick else { return nil }
            return ["name": track.name, "artist": track.artist, "position": index]
        }
        // Tonight's recordings of them, newest first.
        mine += Performances.shared.tonight(by: nick).map {
            ["name": $0.name, "artist": $0.artist, "recording": "/p/\($0.id)"]
        }
        return (try? JSONSerialization.data(withJSONObject: mine)) ?? Data("[]".utf8)
    }

    /// What's on now, for the card at the top of the guest page: the song,
    /// and who asked for it.
    private func playingJSON() -> Data {
        guard let model, let track = model.track else { return Data("{}".utf8) }
        var json: [String: Any] = ["uri": track.uri, "name": track.name, "artist": track.artist]
        if let singer = requester(name: track.name, artist: track.artist) { json["singer"] = singer }
        if let game = gameJSON(for: track) {
            json["game"] = game
            // The question isn't to be read off the card.
            if game["open"] as? Bool == true { json["name"] = "???"; json["artist"] = "Name that tune!" }
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }

    /// The cover, 240 px: plenty for a thumbnail, light on party Wi-Fi.
    private func guestArtwork() async -> Data? {
        guard let model, let track = model.track else { return nil }
        if let guestArt, guestArt.uri == track.uri { return guestArt.data }
        guard let jpeg = await model.coverImage()?.squareJPEG(side: 240, quality: 0.8),
              model.track?.uri == track.uri else { return nil }
        guestArt = (track.uri, jpeg)
        return jpeg
    }

    /// Songs a returning guest has sung here before, from History by the name
    /// they request under, ready to request again: library IDs, as search
    /// results have.
    private func historyJSON(_ route: String) async -> Data {
        let empty = Data(#"{"songs":[]}"#.utf8)
        let nick = (Self.queryValue("nick", in: route)?
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? "").trimmingCharacters(in: .whitespaces)
        guard Self.guestHistory, !nick.isEmpty, nick.count <= 16,
              let music = library as? AppleMusicController else { return empty }
        let key = Setlists.folded(nick)
        if let hit = historyCache[key], Date().timeIntervalSince(hit.at) < 30 { return hit.data }

        let songs = Setlists.shared.pastSongs(of: nick)
        let ids = await music.databaseIDs(persistentIDs: songs.map(\.persistentID))
        let tonight = Setlists.night(for: Date())
        let rows = songs.compactMap { song -> [String: Any]? in
            guard let id = ids[song.persistentID] else { return nil }
            var row: [String: Any] = ["id": id, "name": song.name, "artist": song.artist, "times": song.times]
            if let level = SongInfo.difficulty(song.name, song.artist) { row["level"] = level.rawValue }
            if let best = song.best { row["best"] = best }
            if Setlists.night(for: song.last) == tonight { row["tonight"] = true }
            return row
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["songs": rows])) ?? empty
        historyCache[key] = (Date(), data)
        return data
    }

    private func searchJSON(_ route: String) async -> Data {
        // "+" means a space before percent-decoding; after, it's a real "+".
        let query = Self.queryValue("q", in: route)?
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? ""
        guard query.count >= 2, let library else { return Data("[]".utf8) }
        let hits = (try? await library.searchLibrary(query)) ?? []
        let json = hits.compactMap { track -> [String: Any]? in
            guard let id = track.databaseID else { return nil }
            var row: [String: Any] = ["id": id, "name": track.name, "artist": track.artist]
            // How hard, where known: from songs played or prepared before.
            if let level = SongInfo.difficulty(track.name, track.artist) { row["level"] = level.rawValue }
            return row
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("[]".utf8)
    }

    /// The remote's search: either player's library, each hit with what
    /// /api/play needs — Apple Music's database ID, or Spotify's URI.
    private func remoteSearchJSON(_ route: String) async -> Data {
        let query = Self.queryValue("q", in: route)?
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? ""
        guard query.count >= 2, let browser else { return Data("[]".utf8) }
        let hits = (try? await browser.searchLibrary(query)) ?? []
        let json = hits.compactMap { track -> [String: Any]? in
            var row: [String: Any] = ["name": track.name, "artist": track.artist]
            if let id = track.databaseID { row["id"] = id } else if let uri = track.uri { row["uri"] = uri } else { return nil }
            if let level = SongInfo.difficulty(track.name, track.artist) { row["level"] = level.rawValue }
            return row
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("[]".utf8)
    }

    private func add(body: Data, on connection: NWConnection) async {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? Int, let library else {
            return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
        }
        // Whoever asked, so the host can see who is waiting on what.
        let nick = (object["nick"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(16)
            .description ?? ""
        do {
            let track = try await library.queueRequest(databaseID: id)
            let who = nick.isEmpty ? "" : "\(nick):  "
            received.insert("\(who)\(track.name) — \(track.artist)", at: 0)
            if received.count > 40 { received.removeLast() }
            Diagnostics.log("requests: queued \(track.name)")
            queueKey = ""               // Up Next has changed; re-read it
            if !nick.isEmpty { requestedBy[Self.songKey(track.name, track.artist)] = nick }
            // The lyrics screen's "up next" may just have changed — and with
            // house music playing to an empty queue, this is what comes next.
            model?.refreshNextUp()
            model?.requestArrived(track)

            let payload = ["ok": true, "name": track.name, "artist": track.artist] as [String: Any]
            return send(200, "application/json",
                        (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(),
                        on: connection)
        } catch {
            return send(500, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
        }
    }

    private static func queryValue(_ name: String, in route: String) -> String? {
        guard let mark = route.firstIndex(of: "?") else { return nil }
        for pair in route[route.index(after: mark)...].components(separatedBy: "&") {
            let bits = pair.components(separatedBy: "=")
            if bits.count == 2, bits[0] == name { return bits[1] }
        }
        return nil
    }

    private func send(_ status: Int, _ type: String, _ body: Data, on connection: NWConnection) {
        LocalHTTP.respond(status, type: type, body: body, on: connection)
    }

    /// The app's own icon for the guest page — from the bundle rather than
    /// `applicationIconImage`, which follows the system theme, since the join
    /// screen wants the light artwork on its own background.
    private static let appIcon: Data? = {
        guard let url = Bundle.main.url(forResource: "StudioOne", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)?.squarePNG(side: 256)
    }()

    /// QR for the session address. Rendered large and scaled down, because the
    /// generator emits one pixel per module and a phone camera needs edges.
    static func qr(for url: URL, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }
}
