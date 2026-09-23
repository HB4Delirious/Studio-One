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

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static let defaultsKey = "musicSource"

    /// Whichever source is driving right now. Both controllers share one error
    /// type, and an error is only ever shown for the source in use, so this is
    /// what lets those messages name the right app.
    static var current: MusicSource {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MusicSource.init(rawValue:)) ?? .spotify
    }
}

/// What the app needs from a player, whichever one is driving.
///
/// Both implementations talk over Apple Events — the same mechanism the handoff
/// notes chose for Spotify, and the reason Apple Music slots in without a new
/// playback architecture.
protocol MusicPlayer: AnyObject, Sendable {
    var source: MusicSource { get }

    /// Whether the player can be told to start a specific track by identifier.
    /// Spotify can, via `play track "spotify:track:…"`; Music cannot usefully.
    var supportsPlayingByID: Bool { get }

    /// Async on purpose: the underlying Apple Event is synchronous and can take
    /// tens of milliseconds — occasionally far more when the player app is busy.
    /// Run on the main thread it blocks drawing, which shows up as stuttering
    /// animation and a highlight that advances in steps instead of gliding.
    func snapshot() async throws -> SpotifySnapshot

    /// Async for the same reason, and run on the same serial queue as the
    /// snapshot. These used to run on the main thread: the window froze until
    /// the player answered, and the script ran alongside a snapshot on the
    /// polling queue, which NSAppleScript does not allow.
    func playPause() async throws
    func next() async throws
    func previous() async throws
    func seek(to seconds: Double) async throws
    func play(uri: String) async throws
    func activate()
}

extension Double {
    /// A number AppleScript turned into text. It writes decimals the way the
    /// Mac's region does — "213,5" in Germany or France — which `Double(_:)`
    /// refuses, so every duration and position read as 0 and the lyrics never
    /// moved. Verified by running the snapshot's coercion under de_DE.
    init?(scripted text: String) {
        self.init(text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "."))
    }
}
