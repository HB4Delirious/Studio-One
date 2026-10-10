import AppKit

/// Drives the Spotify desktop app over Apple Events.
///
/// Its scripting dictionary is the current track, the transport and the
/// volume — nothing else. The library comes from the Web API instead (see
/// `SpotifyAccount`), and plays back through here by URI.
final class SpotifyController: MusicPlayer, @unchecked Sendable {

    var source: MusicSource { .spotify }

    let scripts = PlayerScripts(bundleID: MusicSource.spotify.bundleID)
    private let snapshotScript: NSAppleScript

    /// Laid out like the Apple Music snapshot, with the artwork URL last.
    private static let snapshotSource = """
    set d to character id 31
    with timeout of 4 seconds
    tell application id "com.spotify.client"
        set ps to player state as text
        if ps is "stopped" then return "stopped"
        try
            set t to current track
            if (id of t) is "" then return "stopped"
        on error
            return "stopped"
        end try
        set aw to ""
        try
            set aw to artwork url of t
        end try
        return ps & d & (id of t) & d & (name of t) & d & (artist of t) & d & (album of t) & d & ((duration of t) as text) & d & ((player position) as text) & d & aw
    end tell
    end timeout
    """

    init() throws {
        snapshotScript = try PlayerScripts.compile(Self.snapshotSource)
    }

    func snapshot() async throws -> PlayerSnapshot {
        let (result, sampledAt, _) = try await scripts.run(snapshotScript)
        guard let raw = result.stringValue else { throw PlayerError.malformedResponse }
        if raw == "stopped" {
            return PlayerSnapshot(state: .stopped, track: nil, position: 0, sampledAt: sampledAt)
        }
        let fields = raw.components(separatedBy: "\u{1F}")
        guard fields.count >= 7 else { throw PlayerError.malformedResponse }

        // Milliseconds; anything under an hour's worth is taken as seconds.
        let duration = Double(scripted: fields[5]) ?? 0
        let track = PlayerTrack(
            uri: fields[1],
            name: fields[2],
            artist: fields[3],
            album: fields[4],
            duration: duration > 3600 ? duration / 1000 : duration,
            artworkURL: fields.count > 7 ? URL(string: fields[7]) : nil)

        return PlayerSnapshot(state: PlaybackState(rawValue: fields[0]) ?? .paused,
                              track: track,
                              position: Double(scripted: fields[6]) ?? 0,
                              sampledAt: sampledAt)
    }

    func playPause() async throws { try await scripts.tell("playpause") }
    func next() async throws { try await scripts.tell("next track") }
    func previous() async throws { try await scripts.tell("previous track") }

    func seek(to seconds: Double) async throws {
        try await scripts.tell("set player position to \(max(0, seconds))")
    }

    /// With a playlist as context, playback carries on through it afterwards;
    /// without one it stops after the track.
    func play(uri: String, context: String?) async throws {
        guard Self.isValidTrackURI(uri) else { throw PlayerError.malformedResponse }
        if let context, Self.isValidContextURI(context) {
            try await scripts.tell("play track \"\(uri)\" in context \"\(context)\"")
        } else {
            try await scripts.tell("play track \"\(uri)\"")
        }
    }

    /// 0–100, or nil when Spotify isn't running.
    func soundVolume() async -> Int? {
        guard let result = try? await scripts.run("tell application id \"\(scripts.bundleID)\" to get sound volume")
        else { return nil }
        return Int(result.int32Value)
    }

    func setSoundVolume(_ value: Int) async {
        _ = try? await scripts.tell("set sound volume to \(min(100, max(0, value)))")
    }

    // MARK: - What may go into a script
    //
    // URIs are interpolated into AppleScript string literals, so only shapes
    // that can't close the literal are let through.

    static func isValidTrackURI(_ uri: String) -> Bool {
        guard uri.hasPrefix("spotify:track:") else { return false }
        let id = uri.dropFirst("spotify:track:".count)
        return !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Playlists, and the Liked Songs collection (`spotify:user:<id>:collection`),
    /// whose user IDs are not always alphanumeric.
    static func isValidContextURI(_ uri: String) -> Bool {
        guard !uri.contains("\""), !uri.contains("\\"), !uri.contains("\n") else { return false }
        if uri.hasPrefix("spotify:playlist:") {
            let id = uri.dropFirst("spotify:playlist:".count)
            return !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber }
        }
        return uri.hasPrefix("spotify:user:") && uri.hasSuffix(":collection")
    }
}
