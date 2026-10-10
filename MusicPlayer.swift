import AppKit

/// Which app is driving playback.
enum MusicSource: String, CaseIterable, Identifiable {
    case spotify
    case appleMusic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spotify:    return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }

    var bundleID: String {
        switch self {
        case .spotify:    return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static let defaultsKey = "musicSource"

    /// The source in use, for naming it in `PlayerError`'s messages.
    static var current: MusicSource {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MusicSource.init(rawValue:)) ?? .spotify
    }
}

// MARK: - What a player reports

struct PlayerTrack: Equatable {
    /// "spotify:track:…", "spotify:local:…" or "am:<persistent ID>".
    var uri: String
    var name: String
    var artist: String
    var album: String
    var duration: Double     // seconds
    var artworkURL: URL?

    /// What everything per song is saved under — sync trim, key, song
    /// settings, cached lyrics and analysis. The URI's last part for Spotify
    /// tracks and Apple Music; all of it for a local file, whose URI ends in
    /// its length in seconds and so isn't unique.
    var trackID: String {
        if uri.hasPrefix("spotify:local:") { return String(uri.dropFirst("spotify:".count)) }
        return uri.components(separatedBy: ":").last ?? uri
    }
}

enum PlaybackState: String {
    case playing, paused, stopped
}

struct PlayerSnapshot {
    var state: PlaybackState
    var track: PlayerTrack?
    var position: Double
    /// `CACurrentMediaTime()` at the midpoint of the Apple Event round trip.
    var sampledAt: CFTimeInterval
}

enum PlayerError: LocalizedError {
    case notRunning
    case notAuthorized
    case notResponding
    case scriptFailed(String)
    case malformedResponse

    var errorDescription: String? {
        let player = MusicSource.current.displayName
        switch self {
        case .notRunning:
            return "\(player) isn't running. Open \(player) and start a track."
        case .notAuthorized:
            return "Studio One needs permission to control \(player). Grant it in System Settings › Privacy & Security › Automation."
        case .notResponding:
            return "\(player) isn't answering. If it's showing a dialog or sign-in window, close that."
        case .scriptFailed(let detail):
            return "\(player) didn't respond: \(detail)"
        case .malformedResponse:
            return "\(player) returned something unreadable."
        }
    }
}

/// What the app needs from a player, whichever one is followed. Both are
/// driven over Apple Events (see `PlayerScripts`).
protocol MusicPlayer: AnyObject, Sendable {
    var source: MusicSource { get }

    /// Async, like everything here: an Apple Event can take from milliseconds
    /// to seconds, and on the main thread it would stall drawing.
    func snapshot() async throws -> PlayerSnapshot
    func playPause() async throws
    func next() async throws
    func previous() async throws
    func seek(to seconds: Double) async throws
    func activate()
}

extension Double {
    /// A number AppleScript turned into text, which follows the Mac's region —
    /// "213,5" in Germany or France, which `Double(_:)` refuses.
    init?(scripted text: String) {
        self.init(text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "."))
    }
}
