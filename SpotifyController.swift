import AppKit
import ApplicationServices
import QuartzCore

// MARK: - Model

struct SpotifyTrack: Equatable {
    var uri: String          // spotify:track:xxxxx
    var name: String
    var artist: String
    var album: String
    var duration: Double     // seconds
    var artworkURL: URL?

    var trackID: String { uri.components(separatedBy: ":").last ?? uri }
}

enum SpotifyPlayerState: String {
    case playing, paused, stopped
}

struct SpotifySnapshot {
    var state: SpotifyPlayerState
    var track: SpotifyTrack?
    var position: Double
    /// `CACurrentMediaTime()` at the midpoint of the Apple Event round trip.
    var sampledAt: CFTimeInterval
}

enum SpotifyControllerError: LocalizedError {
    case notRunning
    case notAuthorized
    case notResponding
    case scriptFailed(String)
    case malformedResponse

    var errorDescription: String? {
        // Named after whichever source is playing: this type is thrown by the
        // Apple Music controller too, and said "Spotify isn't running" while
        // Music was the one that wasn't answering.
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

// MARK: - Controller

final class SpotifyController: MusicPlayer, @unchecked Sendable {

    var source: MusicSource { .spotify }
    var supportsPlayingByID: Bool { true }

    static let bundleID = "com.spotify.client"

    /// One compiled script, reused for every poll. Compiling on each call would cost ~50 ms.
    private let snapshotScript: NSAppleScript

    /// Fields are joined with U+001F (unit separator) so track titles containing
    /// tabs, pipes or commas can't corrupt the parse.
    private static let snapshotSource = """
    set d to character id 31
    with timeout of 4 seconds
    tell application id "com.spotify.client"
        set ps to player state as text
        if ps is "stopped" then return "stopped"
        set t to current track
        set aw to ""
        try
            set aw to artwork url of t
        end try
        return ps & d & (id of t) & d & (name of t) & d & (artist of t) & d & (album of t) & d & ((duration of t) as text) & d & ((player position) as text) & d & aw
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

    // MARK: Availability & permission

    static var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Asks macOS whether we're allowed to send Apple Events to Spotify.
    /// Pass `prompt: true` once at launch to trigger the system consent dialog.
    @discardableResult
    static func checkAutomationPermission(for bundleID: String = SpotifyController.bundleID,
                                          prompt: Bool) -> Bool {
        var target = AEAddressDesc()
        let idData = Data(bundleID.utf8)
        // AECreateDesc returns OSErr (Int16); widen so it compares against noErr (OSStatus).
        let created = idData.withUnsafeBytes { buffer -> OSStatus in
            OSStatus(AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target))
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt)
        return status == noErr
    }

    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Reading state

    /// All AppleScript for this controller runs here. Serial, because
    /// NSAppleScript is not safe to use concurrently.
    private let scriptQueue = DispatchQueue(label: "com.logan.SpotifyKaraoke.script.spotify")

    func snapshot() async throws -> SpotifySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                do { continuation.resume(returning: try self.snapshotNow()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func snapshotNow() throws -> SpotifySnapshot {
        guard Self.isSpotifyRunning else { throw SpotifyControllerError.notRunning }

        let start = CACurrentMediaTime()
        var error: NSDictionary?
        let result = snapshotScript.executeAndReturnError(&error)
        let end = CACurrentMediaTime()

        if let error { throw Self.mapError(error) }
        guard let raw = result.stringValue else { throw SpotifyControllerError.malformedResponse }

        // Charge half the round trip to the reading — the value was true somewhere in the middle.
        let sampledAt = start + (end - start) / 2

        if raw == "stopped" {
            return SpotifySnapshot(state: .stopped, track: nil, position: 0, sampledAt: sampledAt)
        }

        let fields = raw.components(separatedBy: "\u{1F}")
        guard fields.count >= 7 else { throw SpotifyControllerError.malformedResponse }

        let state = SpotifyPlayerState(rawValue: fields[0]) ?? .paused
        let rawDuration = Double(scripted: fields[5]) ?? 0
        // Spotify reports duration in milliseconds; guard anyway in case that ever changes.
        let duration = rawDuration > 3600 ? rawDuration / 1000 : rawDuration
        let position = Double(scripted: fields[6]) ?? 0
        let artwork = fields.count > 7 ? URL(string: fields[7]) : nil

        let track = SpotifyTrack(
            uri: fields[1],
            name: fields[2],
            artist: fields[3],
            album: fields[4],
            duration: duration,
            artworkURL: artwork
        )

        return SpotifySnapshot(state: state, track: track, position: position, sampledAt: sampledAt)
    }

    // MARK: Transport

    func playPause() async throws { try await run("playpause") }
    func next() async throws { try await run("next track") }
    func previous() async throws { try await run("previous track") }

    func seek(to seconds: Double) async throws {
        try await run("set player position to \(max(0, seconds))")
    }

    func play(uri: String) async throws {
        try await play(uri: uri, context: nil)
    }

    /// With a context, Spotify carries on through the playlist afterwards;
    /// without one it plays the single track.
    func play(uri: String, context: String?) async throws {
        guard Self.isValidTrackURI(uri) else { throw SpotifyControllerError.malformedResponse }
        if let context, Self.isValidContextURI(context) {
            try await run("play track \"\(uri)\" in context \"\(context)\"")
        } else {
            try await run("play track \"\(uri)\"")
        }
    }

    /// The context goes inside an AppleScript string literal, so anything that
    /// could close the literal is refused. Covers playlists and the Liked Songs
    /// collection (`spotify:user:<id>:collection`); user IDs are not always
    /// alphanumeric, so that part is only checked for quotes and backslashes.
    static func isValidContextURI(_ uri: String) -> Bool {
        guard !uri.contains("\""), !uri.contains("\\"), !uri.contains("\n") else { return false }
        if uri.hasPrefix("spotify:playlist:") {
            let id = uri.dropFirst("spotify:playlist:".count)
            return !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber }
        }
        return uri.hasPrefix("spotify:user:") && uri.hasSuffix(":collection")
    }

    func activate() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID)
            .first?
            .activate()
    }

    /// Spotify's own volume, 0–100, on the script queue like every other
    /// Apple Event to it. Nil when Spotify isn't running.
    func soundVolume() async -> Int? {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                guard Self.isSpotifyRunning,
                      let script = NSAppleScript(source: "tell application id \"com.spotify.client\" to get sound volume") else {
                    return continuation.resume(returning: nil)
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? Int(result.int32Value) : nil)
            }
        }
    }

    func setSoundVolume(_ value: Int) async {
        let clamped = min(100, max(0, value))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scriptQueue.async {
                if Self.isSpotifyRunning {
                    var error: NSDictionary?
                    NSAppleScript(source: "tell application id \"com.spotify.client\" to set sound volume to \(clamped)")?
                        .executeAndReturnError(&error)
                }
                continuation.resume()
            }
        }
    }

    // MARK: Plumbing

    /// On the script queue, like the snapshot: never the main thread, and
    /// never alongside another script.
    private func run(_ command: String) async throws {
        // Bounded; see the Apple Music controller.
        let source = """
        with timeout of 10 seconds
            tell application id "com.spotify.client" to \(command)
        end timeout
        """
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            scriptQueue.async {
                guard Self.isSpotifyRunning else {
                    return continuation.resume(throwing: SpotifyControllerError.notRunning)
                }
                guard let script = NSAppleScript(source: source) else {
                    return continuation.resume(throwing: SpotifyControllerError.malformedResponse)
                }
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                if let error { continuation.resume(throwing: Self.mapError(error)) }
                else { continuation.resume() }
            }
        }
    }

    /// Only ever interpolate strings we've validated into AppleScript source.
    static func isValidTrackURI(_ uri: String) -> Bool {
        guard uri.hasPrefix("spotify:track:") else { return false }
        let id = uri.dropFirst("spotify:track:".count)
        return !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber }
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
