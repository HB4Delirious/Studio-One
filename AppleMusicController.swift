import AppKit
import QuartzCore

/// Drives Apple Music (Music.app) over Apple Events, mirroring SpotifyController.
///
/// Music's dictionary is richer than Spotify's, but differs in two ways that
/// matter here: `duration` is already in seconds rather than milliseconds, and
/// there is no artwork URL — artwork is embedded image data, so the app runs
/// without cover art on this source.
final class AppleMusicController: MusicPlayer, @unchecked Sendable {

    var source: MusicSource { .appleMusic }

    /// Music has no equivalent of `play track "spotify:track:…"`, so the search
    /// sheet is Spotify-only.
    var supportsPlayingByID: Bool { false }

    private let snapshotScript: NSAppleScript

    /// Fields joined with U+001F so titles containing punctuation can't corrupt
    /// the parse — same approach as the Spotify snapshot.
    private static let snapshotSource = """
    set d to character id 31
    with timeout of 4 seconds
    tell application id "com.apple.Music"
        set ps to player state as text
        if ps is "stopped" then return "stopped"
        set t to current track
        set pid to ""
        try
            set pid to persistent ID of t
        end try
        return ps & d & pid & d & (name of t) & d & (artist of t) & d & (album of t) & d & ((duration of t) as text) & d & ((player position) as text)
    end tell
    end timeout
    """

    init() throws {
        guard let script = NSAppleScript(source: Self.snapshotSource) else {
            throw SpotifyControllerError.malformedResponse
        }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        if let error {
            throw SpotifyControllerError.scriptFailed(Self.describe(error))
        }
        self.snapshotScript = script
    }

    /// All AppleScript for this controller runs here. Serial, because
    /// NSAppleScript is not safe to use concurrently.
    private let scriptQueue = DispatchQueue(label: "com.logan.SpotifyKaraoke.script.applemusic")

    func snapshot() async throws -> SpotifySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                do { continuation.resume(returning: try self.snapshotNow()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func snapshotNow() throws -> SpotifySnapshot {
        guard MusicSource.appleMusic.isRunning else { throw SpotifyControllerError.notRunning }

        let start = CACurrentMediaTime()
        var error: NSDictionary?
        let result = snapshotScript.executeAndReturnError(&error)
        let end = CACurrentMediaTime()

        if let error { throw Self.mapError(error) }
        guard let raw = result.stringValue else { throw SpotifyControllerError.malformedResponse }

        // Charge half the round trip to the reading — it was true mid-call.
        let sampledAt = start + (end - start) / 2

        // A snapshot is normally tens of milliseconds. Anything approaching the
        // poll interval means the clock has been free-wheeling, which is what
        // the lyrics drifting looks like from the outside.
        let elapsed = (end - start) * 1000
        if elapsed > 250 {
            Diagnostics.log(String(format: "  slow snapshot: %.0f ms", elapsed))
        }

        if raw == "stopped" {
            return SpotifySnapshot(state: .stopped, track: nil, position: 0, sampledAt: sampledAt)
        }

        let fields = raw.components(separatedBy: "\u{1F}")
        guard fields.count >= 7 else { throw SpotifyControllerError.malformedResponse }

        // Music reports "fast forwarding" and "rewinding" too; treat anything
        // that isn't playing or stopped as paused.
        let state = SpotifyPlayerState(rawValue: fields[0]) ?? .paused

        // Already seconds here, unlike Spotify's milliseconds.
        let duration = Double(scripted: fields[5]) ?? 0
        let position = Double(scripted: fields[6]) ?? 0

        // Persistent ID is stable across launches, so per-track settings — sync
        // trim, manual key, tempo correction — stick the way they do on Spotify.
        let identifier = fields[1].isEmpty
            ? "am:\(fields[2])-\(fields[3])"
            : "am:\(fields[1])"

        let track = SpotifyTrack(
            uri: identifier,
            name: fields[2],
            artist: fields[3],
            album: fields[4],
            duration: duration,
            artworkURL: nil)

        return SpotifySnapshot(state: state, track: track, position: position, sampledAt: sampledAt)
    }

    func playPause() async throws { try await run("playpause") }
    func next() async throws { try await run("next track") }
    func previous() async throws { try await run("previous track") }

    func seek(to seconds: Double) async throws {
        try await run("set player position to \(max(0, seconds))")
    }

    /// Not supported — Music can't be told to play an arbitrary identifier.
    func play(uri: String) async throws {
        throw SpotifyControllerError.malformedResponse
    }

    func activate() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: MusicSource.appleMusic.bundleID)
            .first?
            .activate()
    }

    /// Bounded, like the snapshot: AppleScript otherwise waits two minutes
    /// for a player stuck behind a dialog, and every button pressed meanwhile
    /// queues behind it. Ten seconds covers a slow Music; beyond that the
    /// status line says it didn't respond.
    private func run(_ command: String) async throws {
        _ = try await runScript("""
        with timeout of 10 seconds
            tell application id "com.apple.Music" to \(command)
        end timeout
        """)
    }

    private static func mapError(_ dict: NSDictionary) -> SpotifyControllerError {
        let code = (dict[NSAppleScript.errorNumber] as? Int) ?? 0
        switch code {
        case -1743, -1744:  return .notAuthorized
        case -600, -609:    return .notRunning
        case -1712:         return .notResponding
        default:            return .scriptFailed(describe(dict))
        }
    }

    private static func describe(_ dict: NSDictionary) -> String {
        (dict[NSAppleScript.errorMessage] as? String) ?? "unknown error"
    }
}

// MARK: - One-off scripts

/// Ad-hoc scripting for the library browser. Kept in this file because it needs
/// `scriptQueue`, and NSAppleScript is not safe to touch from two threads.
///
/// Unlike `snapshotScript` these are not pre-compiled and held: they are built
/// per call, because they carry playlist and track indices. The compile cost is
/// small next to the Apple Event round trip, and browsing is user-paced rather
/// than per-frame.
extension AppleMusicController {

    func runScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                do { continuation.resume(returning: try self.execute(source).stringValue ?? "") }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func runScriptData(_ source: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                do { continuation.resume(returning: try self.execute(source).data) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard MusicSource.appleMusic.isRunning else { throw SpotifyControllerError.notRunning }
        guard let script = NSAppleScript(source: source) else {
            throw SpotifyControllerError.malformedResponse
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw Self.mapError(error) }
        return result
    }
}
