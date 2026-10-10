import AppKit

/// Drives Apple Music (Music.app) over Apple Events.
///
/// Two differences from Spotify matter here: `duration` is already in seconds,
/// and there is no artwork URL — covers are image data, fetched separately
/// (see `MusicBrowser.currentArtwork`).
final class AppleMusicController: MusicPlayer, @unchecked Sendable {

    var source: MusicSource { .appleMusic }

    let scripts = PlayerScripts(bundleID: MusicSource.appleMusic.bundleID)
    private let snapshotScript: NSAppleScript

    /// Fields are joined with U+001F, which no title contains. Paused with no
    /// track at all (Music just opened, or its queue cleared) is reported as
    /// stopped rather than raising "Can't get current track".
    private static let snapshotSource = """
    set d to character id 31
    with timeout of 4 seconds
    tell application id "com.apple.Music"
        set ps to player state as text
        if ps is "stopped" then return "stopped"
        try
            set t to current track
        on error
            return "stopped"
        end try
        set pid to ""
        try
            set pid to persistent ID of t
        end try
        return ps & d & pid & d & (name of t) & d & (artist of t) & d & (album of t) & d & ((duration of t) as text) & d & ((player position) as text)
    end tell
    end timeout
    """

    init() throws {
        snapshotScript = try PlayerScripts.compile(Self.snapshotSource)
    }

    func snapshot() async throws -> PlayerSnapshot {
        let (result, sampledAt, took) = try await scripts.run(snapshotScript)
        // Normally tens of milliseconds. Near the poll interval, the lyric
        // clock has been free-wheeling in between.
        if took > 0.25 { Diagnostics.log(String(format: "  slow snapshot: %.0f ms", took * 1000)) }

        guard let raw = result.stringValue else { throw PlayerError.malformedResponse }
        if raw == "stopped" {
            return PlayerSnapshot(state: .stopped, track: nil, position: 0, sampledAt: sampledAt)
        }
        let fields = raw.components(separatedBy: "\u{1F}")
        guard fields.count >= 7 else { throw PlayerError.malformedResponse }

        // The persistent ID survives relaunches, so per-song settings stick;
        // title and artist stand in for the rare track without one.
        let track = PlayerTrack(
            uri: fields[1].isEmpty ? "am:\(fields[2])-\(fields[3])" : "am:\(fields[1])",
            name: fields[2],
            artist: fields[3],
            album: fields[4],
            duration: Double(scripted: fields[5]) ?? 0,
            artworkURL: nil)

        // "fast forwarding" and "rewinding" count as paused.
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
}
