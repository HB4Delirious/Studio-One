import ActivityKit
import Network
import Observation
import UIKit
import os

private let log = Logger(subsystem: "com.logan.studioone.remote", category: "activity")

/// What Studio One's /api/state says.
struct RemoteState: Decodable, Equatable {
    struct Song: Decodable, Equatable, Hashable {
        let name: String
        let artist: String
        var singer: String?
    }

    var playing = false
    var position = 0.0
    var name: String?
    var artist: String?
    var singer: String?
    var duration: Double?
    var artKey: String?
    var key: String?
    var tempo: Int?
    var corrected: Bool?
    var queue: [Song]?
    var queueEditable: Bool?
    var volume: Int?
    var source: String?
    var canRequest: Bool?
    var house: Bool?
    var intermission: Bool?
    var breakEnds: Double?
    var next: Song?
}

struct SearchHit: Decodable, Identifiable, Hashable {
    var id: String { uri ?? databaseID.map(String.init) ?? name + artist }
    let name: String
    let artist: String
    let databaseID: Int?
    let uri: String?
    let level: Int?

    enum CodingKeys: String, CodingKey {
        case name, artist, uri, level
        case databaseID = "id"
    }
}

/// The paired Mac, as this phone sees it: polled every second and a half
/// while the app is open, found again by Bonjour if its address changes.
@MainActor
@Observable
final class RemoteStore {
    static let shared = RemoteStore()

    private(set) var pairing: Pairing? = Pairing.saved
    private(set) var state: RemoteState?
    /// When `state` arrived, for running the clock between polls.
    private(set) var stateAt = Date()
    private(set) var artwork: UIImage?
    private(set) var reachable = true
    private(set) var finding = false

    let activity = ActivityController()

    private var poller: Task<Void, Never>?
    private var artKey: String?
    private var failures = 0

    var position: Double {
        guard let state else { return 0 }
        let running = state.playing ? Date().timeIntervalSince(stateAt) : 0
        return min(state.duration ?? .infinity, state.position + running)
    }

    // MARK: - Pairing

    /// Tries the code, and keeps it if the Mac answers.
    func pair(with candidate: Pairing) async -> Bool {
        guard let data = try? await RemoteAPI.get("api/state", from: candidate),
              let state = try? JSONDecoder().decode(RemoteState.self, from: data) else { return false }
        var paired = candidate
        if paired.name == nil, let found = await MacFinder.find(id: candidate.macID, timeout: 3) { paired.name = found.name }
        save(paired)
        apply(state)
        startPolling()
        return true
    }

    func unpair() {
        stopPolling()
        activity.end()
        Pairing.saved = nil
        pairing = nil
        state = nil
        artwork = nil
        artKey = nil
    }

    private func save(_ new: Pairing) {
        Pairing.saved = new
        pairing = new
    }

    // MARK: - Polling

    func startPolling() {
        guard pairing != nil, poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    func refresh() async {
        guard let pairing else { return }
        do {
            let data = try await RemoteAPI.get("api/state", from: pairing)
            apply(try JSONDecoder().decode(RemoteState.self, from: data))
            failures = 0
            reachable = true
        } catch {
            failures += 1
            // A few misses in a row: the Mac may have a new address.
            if failures >= 3 {
                reachable = false
                await findAgain()
            }
        }
    }

    private func apply(_ new: RemoteState) {
        state = new
        stateAt = Date()
        if new.artKey != artKey {
            artKey = new.artKey
            Task { await loadArtwork() }
        }
        activity.update(with: new, at: stateAt, mac: pairing?.name ?? "Studio One")
    }

    private func loadArtwork() async {
        guard let pairing, state?.artKey != nil else { artwork = nil; return }
        // The Mac reads the cover as the state's first poll for a song comes
        // in, so give it a moment.
        try? await Task.sleep(for: .milliseconds(400))
        artwork = (try? await RemoteAPI.get("api/artwork", from: pairing)).flatMap(UIImage.init(data:))
    }

    /// Bonjour: the Mac with this pairing's ID, wherever it is now.
    func findAgain() async {
        guard var pairing, !finding else { return }
        finding = true
        defer { finding = false }
        guard let found = await MacFinder.find(id: pairing.macID, timeout: 5) else { return }
        guard found.host != pairing.host || found.port != pairing.port || pairing.name == nil else { return }
        pairing.host = found.host
        pairing.port = found.port
        pairing.name = found.name
        save(pairing)
        failures = 0
    }

    // MARK: - Doing things

    func command(_ name: String, extra: [String: Any] = [:]) {
        Task {
            try? await RemoteAPI.command(name, extra: extra)
            await refresh()
        }
    }

    func seek(to seconds: Double) {
        command("seek", extra: ["to": seconds])
    }

    func setVolume(_ value: Int) {
        guard let pairing else { return }
        Task { _ = try? await RemoteAPI.post("api/volume", ["value": value], to: pairing) }
    }

    func nudge(_ what: String, by: Int = 0) {
        guard let pairing else { return }
        Task {
            _ = try? await RemoteAPI.post("api/nudge", ["what": what, "by": by], to: pairing)
            await refresh()
        }
    }

    func move(from: Int, to: Int) {
        guard let pairing else { return }
        Task {
            _ = try? await RemoteAPI.post("api/reorder", ["from": from, "to": to], to: pairing)
            await refresh()
        }
    }

    func search(_ query: String) async -> [SearchHit] {
        guard let pairing, query.count >= 2,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: pairing.base.absoluteString + "/api/search?q=" + encoded) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return [] }
        return (try? JSONDecoder().decode([SearchHit].self, from: data)) ?? []
    }

    func play(_ hit: SearchHit) {
        guard let pairing else { return }
        let body: [String: Any] = hit.databaseID.map { ["id": $0] } ?? ["uri": hit.uri ?? ""]
        Task {
            _ = try? await RemoteAPI.post("api/play", body, to: pairing)
            await refresh()
        }
    }

    /// Into Apple Music's requests playlist, as the host.
    func request(_ hit: SearchHit) async -> Bool {
        guard let pairing, let id = hit.databaseID else { return false }
        return (try? await RemoteAPI.post("api/add", ["id": id, "nick": "Host"], to: pairing)) != nil
    }
}

/// Finds Studio One on the network by Bonjour and resolves it to an address.
enum MacFinder {
    struct Found {
        let host: String
        let port: Int
        let name: String
    }

    /// The Mac whose TXT record carries `id` (or, with no ID, the first one).
    static func find(id: String?, timeout: Double) async -> Found? {
        await withCheckedContinuation { continuation in
            let once = Once()
            let queue = DispatchQueue(label: "finder")
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_studioone._tcp", domain: nil), using: .tcp)
            @Sendable func finish(_ found: Found?) {
                guard once.claim() else { return }
                browser.cancel()
                continuation.resume(returning: found)
            }
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    if let id, case .bonjour(let record) = result.metadata, record["id"] != id { continue }
                    resolve(result.endpoint, queue: queue) { host, port in
                        if let host, let port { finish(Found(host: host, port: port, name: name)) }
                    }
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// A connection to the service, over IPv4, just long enough to learn its
    /// address and port.
    private static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue,
                                then: @escaping (String?, Int?) -> Void) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    var text = "\(host)"
                    if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                    then(text, Int(port.rawValue))
                } else {
                    then(nil, nil)
                }
                connection.cancel()
            case .failed, .cancelled:
                then(nil, nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

/// The Lock Screen's Live Activity: started when a song is playing and the
/// app is open, updated as the song, singer or next song change, ended when
/// nothing plays. Without push (a free developer account can't), it's only
/// as fresh as the app's last look — the progress bar runs by itself.
@MainActor
final class ActivityController {
    static let enabledKey = "liveActivity"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var current: Activity<RemoteActivityAttributes>? = Activity<RemoteActivityAttributes>.activities.first
    private var shown: RemoteActivityAttributes.ContentState?

    func update(with state: RemoteState, at received: Date, mac: String) {
        guard Self.enabled, let title = state.name, let artist = state.artist else { return end() }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("Live Activities are off for this app in Settings")
            return end()
        }
        let duration = max(1, state.duration ?? 1)
        let started = received.addingTimeInterval(-state.position)
        let content = RemoteActivityAttributes.ContentState(
            title: title, artist: artist, singer: state.singer,
            nextTitle: state.next?.name, nextSinger: state.next?.singer,
            playing: state.playing, started: started, ends: started.addingTimeInterval(duration),
            pausedAt: state.playing ? nil : state.position,
            intermission: state.intermission ?? false,
            breakEnds: state.breakEnds.map(Date.init(timeIntervalSince1970:)),
            houseMusic: state.house ?? false)
        // Polls drift by milliseconds: only a real change is sent.
        if let shown, Self.same(shown, content) { return }
        shown = content
        let update = ActivityContent(state: content, staleDate: content.ends.addingTimeInterval(30))
        if let current, current.activityState == .active {
            Task { await current.update(update) }
        } else {
            do {
                current = try Activity.request(attributes: RemoteActivityAttributes(macName: mac), content: update, pushType: nil)
                log.notice("started a Live Activity for \(title, privacy: .public)")
            } catch {
                log.error("couldn't start a Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func end() {
        shown = nil
        current = nil
        Task {
            for activity in Activity<RemoteActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func same(_ a: RemoteActivityAttributes.ContentState, _ b: RemoteActivityAttributes.ContentState) -> Bool {
        var b = b
        if abs(a.started.timeIntervalSince(b.started)) < 2 {
            b.started = a.started
            b.ends = a.ends
        }
        if let x = a.pausedAt, let y = b.pausedAt, abs(x - y) < 2 { b.pausedAt = a.pausedAt }
        return a == b
    }
}
