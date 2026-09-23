import AppKit
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI

/// A request line for the party: guests on the same Wi-Fi scan a QR code, search
/// the host's library, and their picks land in a playlist.
///
/// Apple Music has no shared-session feature of its own, and nothing in its
/// scripting dictionary reaches the catalogue — `search` searches a playlist.
/// So the pool guests can request from is the host's own library, and the queue
/// is a real playlist ("Studio One Requests") that Music owns. That is what
/// makes the Up Next panel work for it with no extra machinery.
///
/// Deliberately small: a handful of routes, no dependencies, and it serves only
/// while it is switched on.
@MainActor
final class RequestServer: ObservableObject {

    static let shared = RequestServer()
    static let enabledKey = "requestServerEnabled"

    @Published private(set) var running = false

    /// Two doors, two tokens. The guest code is meant to be shown to a room;
    /// the remote code is not, because it can skip, seek and start tracks.
    /// One token for both would mean handing the room the transport.
    @Published private(set) var guestAddress: URL?
    @Published private(set) var remoteAddress: URL?
    @Published private(set) var failure: String?
    @Published private(set) var received: [String] = []

    private var listener: NWListener?
    private var browser: MusicBrowser?
    private weak var model: KaraokeModel?
    private var guestToken = ""
    private var remoteToken = ""

    /// Up Next and cover art each cost an Apple Event, and the remote polls
    /// every two seconds. Both are held until the track changes.
    private var cachedQueue: [LibraryTrack] = []

    /// Who asked for what, by title and artist — the only handle Up Next and
    /// the playing track share. Latest request wins for a song asked twice.
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
    private var cacheKey = ""
    /// Volume is read once and then tracked locally: re-reading it every poll
    /// is an Apple Event for a number that only changes when we change it.
    private var cachedVolume: Int?
    private var volumeReadAt = Date.distantPast

    /// The path carries a random token so a device that merely shares the Wi-Fi
    /// can't wander in by guessing the port. It is not a password — anyone shown
    /// the code can request — but it keeps the door from standing open.
    private static func makeToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    /// Between pressing Start and the port answering.
    private var starting = false
    private var attempt = 0

    func start(model: KaraokeModel) {
        guard !running, !starting else { return }
        guard let browser = model.browser, browser.canTakeRequests else {
            failure = "Requests need a library to search. Switch to Apple Music."
            return
        }
        self.browser = browser
        self.model = model
        guestToken = Self.makeToken()
        remoteToken = Self.makeToken()

        // A fixed port would collide with whatever else is listening; walking a
        // few keeps the QR honest without asking the user to pick one.
        guard let host = Self.localAddress() else {
            failure = "No Wi-Fi address — the Mac has to be on the same network as your guests."
            return
        }
        starting = true
        failure = nil
        attempt += 1
        let thisAttempt = attempt
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
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in self?.accept(connection) }
                    }
                })
            // Stopped while the port was being found: let it go.
            guard thisAttempt == attempt else { opened?.listener.cancel(); return }
            starting = false
            guard let (listener, port) = opened else {
                failure = "Couldn't open a port in 8710–8719."
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    if case .failed(let error) = state {
                        self.failure = error.localizedDescription
                        self.stop()
                    }
                }
            }
            self.listener = listener
            guestAddress = URL(string: "http://\(host):\(port)/s/\(guestToken)")
            remoteAddress = URL(string: "http://\(host):\(port)/r/\(remoteToken)")
            running = true
            Diagnostics.log("requests: listening on \(host):\(port)")
        }
    }

    /// With a reason, shown where the codes were.
    func stop(because reason: String) {
        stop()
        failure = reason
    }

    func stop() {
        attempt += 1
        starting = false
        listener?.cancel()
        listener = nil
        running = false
        guestAddress = nil
        remoteAddress = nil
        Diagnostics.log("requests: stopped")
    }

    /// The Mac's address on the local network. Wi-Fi first, then wired — a Mac
    /// plugged into ethernet with Wi-Fi off still has guests on the same LAN.
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
            // 169.254 is what an interface gives itself when no network
            // answered; a QR code pointing there reaches nobody.
            guard !address.hasPrefix("169.254.") else { continue }
            candidates[name] = address
        }
        return candidates["en0"] ?? candidates["en1"] ?? candidates.values.sorted().first
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, complete, error in
            guard let self else { return }
            var data = buffer
            if let chunk { data.append(chunk) }

            if error != nil || (complete && data.isEmpty) {
                connection.cancel()
                return
            }
            // Headers end at the blank line. A POST body follows, so wait for
            // Content-Length bytes of it before answering.
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
                if data.count > 64 * 1024 { connection.cancel() } else {
                    Task { @MainActor in self.read(connection, buffer: data) }
                }
                return
            }
            let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
            let expected = Self.contentLength(in: header)
            // Nothing here takes more than a song request. A larger body is
            // never going to be answered, so don't hold it in memory waiting.
            guard expected <= Self.maxBody else {
                connection.cancel()
                return
            }
            let body = data[headerEnd.upperBound...]
            if body.count < expected {
                Task { @MainActor in self.read(connection, buffer: data) }
                return
            }
            Task { @MainActor in
                await self.respond(to: header, body: Data(body), on: connection)
            }
        }
    }

    nonisolated private static let maxBody = 16 * 1024

    nonisolated private static func contentLength(in header: String) -> Int {
        for line in header.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func respond(to header: String, body: Data, on connection: NWConnection) async {
        guard let requestLine = header.components(separatedBy: "\r\n").first else {
            return send(404, "text/plain", Data("bad request".utf8), on: connection)
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return send(404, "text/plain", Data("bad request".utf8), on: connection)
        }
        let method = parts[0]
        let target = parts[1]
        let guestRoot = "/s/\(guestToken)"
        let remoteRoot = "/r/\(remoteToken)"

        if target.hasPrefix(remoteRoot) {
            return await remote(String(target.dropFirst(remoteRoot.count)),
                                method: method, body: body, on: connection)
        }
        guard target.hasPrefix(guestRoot) else {
            // Wrong or missing token: say nothing useful.
            return send(404, "text/plain", Data("not found".utf8), on: connection)
        }
        let route = String(target.dropFirst(guestRoot.count))

        if method == "GET", route.isEmpty || route == "/" {
            return send(200, "text/html; charset=utf-8", Data(RequestPages.guest(code: guestToken).utf8), on: connection)
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

        if method == "POST", route.hasPrefix("/api/add") {
            return await add(body: body, on: connection)
        }

        send(404, "text/plain", Data("not found".utf8), on: connection)
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
            return send(200, "application/json", await searchJSON(route), on: connection)
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
            case "seek":      if let to = object["to"] as? Double { model.seek(to: to) }
            default:          break
            }
            return send(200, "application/json", Data(#"{"ok":true}"#.utf8), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/play") {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = object["id"] as? Int, let browser else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            try? await browser.playNow(databaseID: id)
            return send(200, "application/json", Data(#"{"ok":true}"#.utf8), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/volume") {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let value = object["value"] as? Int, let browser else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            cachedVolume = min(100, max(0, value))
            volumeReadAt = Date()
            await browser.setVolume(value)
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
                  let browser, cachedEditable else {
                return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
            }
            do { try await browser.reorderQueue(from: from, to: to) }
            catch { Diagnostics.log("ERROR reorder: \(error.localizedDescription)") }
            cacheKey = ""                       // force a re-read on the next poll
            model?.refreshNextUp()
            return send(200, "application/json", Data(#"{"ok":true}"#.utf8), on: connection)
        }

        if method == "POST", route.hasPrefix("/api/add") {
            cacheKey = ""
            return await add(body: body, on: connection)
        }

        send(404, "text/plain", Data("not found".utf8), on: connection)
    }

    private func stateJSON() async -> Data {
        var state: [String: Any] = [:]
        guard let model else { return Data("{}".utf8) }
        state["playing"] = model.isPlaying
        state["position"] = model.playbackPosition

        if let track = model.track {
            state["name"] = track.name
            state["artist"] = track.artist
            state["duration"] = track.duration
            state["artKey"] = track.uri

            // One Apple Event per track change, not one per poll.
            if cacheKey != track.uri {
                cacheKey = track.uri
                await refreshQueue()
                cachedEditable = await browser?.queueIsEditable() ?? false
                cachedArtwork = (await browser?.currentArtwork()).flatMap(Self.cover(from:))
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
        // Re-read now and then: the volume also changes in Music itself and
        // from the Stream Deck, and a remote stuck on an old value fights them.
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

    /// A guest's own requests and where each stands: 0 is singing now, 1 is
    /// next, and so on. Read from Up Next, so it is Music's real order.
    private func mineJSON(_ route: String) async -> Data {
        let nick = (Self.queryValue("nick", in: route)?
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? "").trimmingCharacters(in: .whitespaces)
        guard !nick.isEmpty else { return Data("[]".utf8) }
        let key = model?.track?.uri ?? ""
        if cacheKey != key {
            cacheKey = key
            await refreshQueue()
        }
        let mine = cachedQueue.enumerated().compactMap { index, track -> [String: Any]? in
            guard requester(name: track.name, artist: track.artist) == nick else { return nil }
            return ["name": track.name, "artist": track.artist, "position": index]
        }
        return (try? JSONSerialization.data(withJSONObject: mine)) ?? Data("[]".utf8)
    }

    private func searchJSON(_ route: String) async -> Data {
        // "+" is a space only before decoding; after it, it is a real plus
        // sign, as in "C+C Music Factory".
        let query = Self.queryValue("q", in: route)?
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? ""
        guard query.count >= 2, let browser else { return Data("[]".utf8) }
        let hits = (try? await browser.searchLibrary(query)) ?? []
        let json = hits.compactMap { track -> [String: Any]? in
            guard let id = track.databaseID else { return nil }
            return ["id": id, "name": track.name, "artist": track.artist]
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("[]".utf8)
    }

    private func add(body: Data, on connection: NWConnection) async {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? Int, let browser else {
            return send(400, "application/json", Data(#"{"ok":false}"#.utf8), on: connection)
        }
        // Whoever asked, so the host can see who is waiting on what.
        let nick = (object["nick"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(16)
            .description ?? ""
        do {
            let track = try await browser.queueRequest(databaseID: id)
            let who = nick.isEmpty ? "" : "\(nick):  "
            received.insert("\(who)\(track.name) — \(track.artist)", at: 0)
            if received.count > 40 { received.removeLast() }
            Diagnostics.log("requests: queued \(track.name)")
            cacheKey = ""               // Up Next has changed; re-read it
            if !nick.isEmpty { requestedBy[Self.songKey(track.name, track.artist)] = nick }
            // The lyrics screen's "up next" may just have changed.
            model?.refreshNextUp()

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
        // Always closing the connection: keep-alive would need a state machine
        // per socket, and a request page is a handful of small round trips.
        let head = """
        HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }


    /// The app's own icon, for the guest page. Read from the bundle rather than
    /// `applicationIconImage`, which follows the system theme — the join screen
    /// has its own background and wants the light artwork either way.
    private static let appIcon: Data? = {
        guard let url = Bundle.main.url(forResource: "StudioOne", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        let side = 256.0
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side),
                                            pixelsHigh: Int(side), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                            bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return target.representation(using: .png, properties: [:])
    }()

    /// Cover art, shrunk for the phone. Straight from Music it is around
    /// 570 KB, which is a lot to push over party Wi-Fi for something rendered
    /// at a few hundred points.
    private static func cover(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let side = 600.0
        let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side),
                                      pixelsHigh: Int(side), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let target else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return target.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

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
