import ActivityKit
import AppIntents
import Foundation

/// The Mac this phone is paired with: where it was last found, its code, and
/// its install ID — what Bonjour finds it by when its address changes.
struct Pairing: Codable, Equatable {
    var host: String
    var port: Int
    var token: String
    var macID: String?
    var name: String?

    static let defaultsKey = "pairing"

    static var saved: Pairing? {
        get { UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Pairing.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: defaultsKey) }
    }

    /// From the code Studio One shows: http://host:port/r/<code>#studioone=<id>.
    init?(scanned text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http", let host = url.host, let port = url.port else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "r", parts[1].count >= 8 else { return nil }
        self.host = host
        self.port = port
        token = String(parts[1])
        macID = url.fragment.flatMap { $0.hasPrefix("studioone=") ? String($0.dropFirst(10)) : nil }
        name = nil
    }

    init(host: String, port: Int, token: String, macID: String?, name: String?) {
        self.host = host
        self.port = port
        self.token = token
        self.macID = macID
        self.name = name
    }

    var base: URL { URL(string: "http://\(host):\(port)/r/\(token)")! }
}

/// Studio One's remote API: the state, and the things a remote can do.
enum RemoteAPI {
    struct Failure: Error {}

    static func get(_ path: String, from pairing: Pairing) async throws -> Data {
        var request = URLRequest(url: pairing.base.appendingPathComponent(path))
        request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure() }
        return data
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any], to pairing: Pairing) async throws -> Data {
        var request = URLRequest(url: pairing.base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 6
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure() }
        return data
    }

    static func command(_ name: String, extra: [String: Any] = [:]) async throws {
        guard let pairing = Pairing.saved else { throw Failure() }
        try await post("api/command", extra.merging(["cmd": name]) { new, _ in new }, to: pairing)
    }

    /// Set by the app: after a Lock Screen button, read the state again and
    /// bring the Live Activity up to date. (The buttons' intents run in the
    /// app's process, never the widget's.)
    nonisolated(unsafe) static var afterCommand: (@Sendable () async -> Void)?
}

/// What the Lock Screen and the Dynamic Island show.
struct RemoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var singer: String?
        var nextTitle: String?
        var nextSinger: String?
        var playing: Bool
        /// When the song started, as if it had played straight through; with
        /// `ends`, the progress bar runs by itself.
        var started: Date
        var ends: Date
        /// The position, while paused.
        var pausedAt: Double?
        var intermission: Bool
        var breakEnds: Date?
        var houseMusic: Bool
    }

    var macName: String
}

struct TogglePlaybackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause"

    func perform() async throws -> some IntentResult {
        try await RemoteAPI.command("playpause")
        await RemoteAPI.afterCommand?()
        return .result()
    }
}

struct NextTrackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Next Song"

    func perform() async throws -> some IntentResult {
        try await RemoteAPI.command("next")
        await RemoteAPI.afterCommand?()
        return .result()
    }
}
