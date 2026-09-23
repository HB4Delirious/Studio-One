import AppKit

/// A playlist in the player's library.
///
/// `index` is its position, which is what the list is keyed by. On Apple
/// Music it is also addressed by `persistentID` whenever that is known: a
/// position shifts the moment a playlist is added or removed — including the
/// requests playlist this app creates — and "user playlist 7" then opens a
/// different one. (An earlier note here said playlists had no persistent ID;
/// Music's dictionary gives every item one, playlists included.)
struct LibraryPlaylist: Identifiable, Hashable {
    let index: Int              // `user playlist N`, 1-based
    let name: String
    var persistentID: String? = nil
    var id: Int { index }
}

/// A track, with enough of a handle to start it playing.
struct LibraryTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String
    let duration: Double

    /// Where to play it from. Music needs both, since `play` is addressed as
    /// `track N of user playlist M`.
    let playlistIndex: Int?
    let trackIndex: Int?

    /// Spotify plays by URI instead.
    let uri: String?

    /// Music's stable per-track identity. Requests travel as this, because a
    /// search result's position means nothing by the time it comes back.
    var databaseID: Int? = nil

    /// Spotify: the playlist to play this within, so the next song follows on
    /// from it instead of playback stopping after one track.
    var contextURI: String? = nil

    /// Apple Music: the playlist's persistent ID, preferred over its position.
    var playlistID: String? = nil
}

struct UpNext {
    let playlistName: String
    let tracks: [LibraryTrack]      // starting at the one now playing
}

/// Browsing on top of `MusicPlayer`, for the players that can support it.
///
/// Only Apple Music can. Spotify's scripting dictionary has no library, no
/// playlists and no queue — its whole surface is the current track, the
/// transport and the volume. Nothing in it is gated behind permission; the
/// properties simply do not exist, so there is nothing to fall back to.
protocol MusicBrowser: AnyObject, Sendable {
    var canBrowseLibrary: Bool { get }

    /// Whether guests can queue songs through the request line. Separate from
    /// browsing since Spotify gained a library: the request line adds songs to a
    /// playlist and reorders it, which Spotify's side of this app cannot do.
    var canTakeRequests: Bool { get }
    func playlists() async throws -> [LibraryPlaylist]
    func tracks(in playlist: LibraryPlaylist) async throws -> [LibraryTrack]
    func upNext(limit: Int) async throws -> UpNext?
    func play(_ track: LibraryTrack) async throws
    func artwork(for track: LibraryTrack) async -> Data?

    /// Cover of whatever is playing. Apple Music has no artwork URL, so this is
    /// the only way to get one on that source — and it feeds the palette that
    /// tints the whole app, not just the panel.
    func currentArtwork() async -> Data?

    /// Search the host's library. This is what guests can request from: Music's
    /// `search` command searches a playlist, so the catalogue is out of reach —
    /// only what the host already has.
    func searchLibrary(_ query: String) async throws -> [LibraryTrack]

    /// Append a track to the requests playlist, creating it if needed.
    /// Returns what was added, for the confirmation the guest sees.
    func queueRequest(databaseID: Int) async throws -> LibraryTrack

    /// What's waiting in the requests playlist.
    func requests() async throws -> [LibraryTrack]

    /// Start the requests playlist. Playing it *as a playlist* is what gives
    /// Music a `current playlist`, and so what makes Up Next show the queue.
    func playRequests() async throws

    /// Play one track straight away, from the remote.
    func playNow(databaseID: Int) async throws

    /// Whether the queue on screen is the requests playlist, and so ours to
    /// rearrange. Anything else is one of the user's own playlists, and
    /// reordering it from a phone would quietly rewrite their library.
    func queueIsEditable() async -> Bool

    /// Move a track within the requests playlist, 1-based, and re-seat Music's
    /// Up Next so the change actually takes effect.
    func reorderQueue(from: Int, to: Int) async throws

    /// The player's own output volume, 0–100. The one audio control Apple Music
    /// actually exposes — there are no stems to balance.
    func volume() async -> Int
    func setVolume(_ value: Int) async
}

enum LibraryError: LocalizedError {
    case noRequests
    var errorDescription: String? {
        switch self {
        case .noRequests: return "Nobody has requested a song yet."
        }
    }
}

// MARK: - Apple Music

/// Every script here reads properties in bulk — `name of every track of p`
/// rather than a `repeat` that asks per track. Measured on a 51-track playlist:
/// 2.71s the loop way, 0.18s this way, and it stays flat as playlists grow (a
/// 96-track playlist came back in 0.16s). Each property crossing the Apple
/// Event boundary once instead of once per track is the whole difference.
extension AppleMusicController: MusicBrowser {

    var canBrowseLibrary: Bool { true }
    var canTakeRequests: Bool { true }

    func playlists() async throws -> [LibraryPlaylist] {
        // Deliberately no track counts. `count of tracks` per playlist took the
        // enumeration from 0.48s to 2.40s, and the count is not worth five times
        // the wait before anything appears.
        let raw = try await runScript("""
        set d to character id 31
        tell application id "com.apple.Music"
            set ns to name of every user playlist
            set ps to persistent ID of every user playlist
            set out to ""
            repeat with i from 1 to count of ns
                set out to out & (item i of ns) & d & (item i of ps) & linefeed
            end repeat
            return out
        end tell
        """)
        return raw.components(separatedBy: "\n")
            .enumerated()
            .compactMap { offset, line in
                let fields = line.components(separatedBy: "\u{1F}")
                let trimmed = fields[0].trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return LibraryPlaylist(index: offset + 1, name: trimmed,
                                       persistentID: fields.count > 1 ? fields[1] : nil)
            }
    }

    /// How a script names a playlist: by persistent ID when known, which
    /// survives the library changing underneath; by position otherwise.
    /// IDs are hex, and anything else is refused rather than put in a script.
    static func playlistReference(index: Int?, id: String?) -> String? {
        if let id, !id.isEmpty, id.allSatisfy(\.isHexDigit) {
            return "(first user playlist whose persistent ID is \"\(id)\")"
        }
        return index.map { "user playlist \($0)" }
    }

    func tracks(in playlist: LibraryPlaylist) async throws -> [LibraryTrack] {
        guard let reference = Self.playlistReference(index: playlist.index, id: playlist.persistentID) else {
            return []
        }
        let raw = try await runScript("""
        set d to character id 31
        tell application id "com.apple.Music"
            set p to \(reference)
            set ns to name of every track of p
            set ar to artist of every track of p
            set du to duration of every track of p
            set di to database ID of every track of p
            set out to ""
            repeat with i from 1 to count of ns
                set out to out & (item i of ns) & d & (item i of ar) & d & ((item i of du) as text) & d & (item i of di) & linefeed
            end repeat
            return out
        end tell
        """)
        return Self.parseTracks(raw, playlistIndex: playlist.index).map {
            var track = $0
            track.playlistID = playlist.persistentID
            return track
        }
    }

    func upNext(limit: Int) async throws -> UpNext? {
        // `current playlist` only exists while something is playing — asking
        // when stopped raises "Can't get current playlist", which is a normal
        // state here rather than a failure.
        //
        // The window is sliced inside the script: a library playlist can hold
        // thousands of tracks, and there is no reason to carry them all across
        // the boundary to show the next few.
        let raw = try await runScript("""
        set d to character id 31
        tell application id "com.apple.Music"
            try
                set p to current playlist
                set ct to current track
            on error
                return "none"
            end try
            set cid to database ID of ct
            set ids to database ID of every track of p
            set total to count of ids
            set idx to 1
            repeat with i from 1 to total
                if item i of ids is cid then
                    set idx to i
                    exit repeat
                end if
            end repeat
            set lim to idx + \(limit) - 1
            if lim > total then set lim to total
            set ns to name of every track of p
            set ar to artist of every track of p
            set du to duration of every track of p
            set out to (name of p)
            repeat with i from idx to lim
                set out to out & linefeed & (item i of ns) & d & (item i of ar) & d & ((item i of du) as text)
            end repeat
            return out
        end tell
        """)
        guard raw != "none" else { return nil }
        var lines = raw.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }
        let name = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        return UpNext(playlistName: name,
                      tracks: Self.parseTracks(lines.joined(separator: "\n"), playlistIndex: nil))
    }

    /// How far in we will skip to reach a chosen track. Each skip is cheap
    /// inside the script — 29 of them took 0.89s — but the cost is linear, and
    /// waiting fifteen seconds to start track 500 is worse than starting it
    /// without a queue.
    private static let skipLimit = 40

    func play(_ track: LibraryTrack) async throws {
        guard let index = track.trackIndex,
              let reference = Self.playlistReference(index: track.playlistIndex, id: track.playlistID) else { return }

        // Music will do one or the other, not both: `play user playlist` builds
        // an Up Next queue but always starts at track 1, while `play track N of
        // user playlist` starts where you asked and leaves the queue empty — so
        // `next track` afterwards does nothing at all. Verified both ways.
        //
        // So for a track near the top, play the playlist and skip to it: the
        // repeat runs inside Music, not as one Apple Event per skip.
        //
        // The track is found by its database ID at the moment of playing: the
        // position it had when the list was read is only a fallback, since a
        // playlist edited meanwhile would otherwise start a different song.
        // Deeper than the skip limit, it starts on its own and nothing follows.
        let wanted = track.databaseID.map(String.init) ?? "0"
        _ = try await runScript("""
        tell application id "com.apple.Music"
            set p to \(reference)
            set idx to \(index)
            if \(wanted) is not 0 then
                set ids to database ID of every track of p
                repeat with i from 1 to count of ids
                    if item i of ids is \(wanted) then
                        set idx to i
                        exit repeat
                    end if
                end repeat
            end if
            if idx ≤ \(Self.skipLimit) then
                play p
                repeat (idx - 1) times
                    next track
                end repeat
            else
                play track idx of p
            end if
        end tell
        """)
    }

    func artwork(for track: LibraryTrack) async -> Data? {
        guard let index = track.trackIndex,
              let reference = Self.playlistReference(index: track.playlistIndex, id: track.playlistID) else { return nil }
        // `data of artwork`, not `raw data`: raw data fails on Apple Music
        // streaming tracks — they come back as "shared track" and refuse it,
        // while `data` returns the picture fine.
        return try? await runScriptData("""
        tell application id "com.apple.Music"
            return data of artwork 1 of track \(index) of \(reference)
        end tell
        """)
    }

    func currentArtwork() async -> Data? {
        try? await runScriptData("""
        tell application id "com.apple.Music"
            return data of artwork 1 of current track
        end tell
        """)
    }

    static let requestsPlaylist = "Studio One Requests"

    func searchLibrary(_ query: String) async throws -> [LibraryTrack] {
        // Quotes would end the AppleScript string literal early, so they are
        // stripped rather than escaped: this text came off the network.
        let safe = query.replacingOccurrences(of: "\"", with: " ")
                        .replacingOccurrences(of: "\\", with: " ")
                        .prefix(80)
        // Each row is read inside its own `try`. Music's search index can hand
        // back a specifier for a track that no longer exists — a deleted URL
        // track leaves one behind until Music restarts — and reading any
        // property of one fails -1700. Without the per-row try that error takes
        // the whole script down, `searchLibrary` throws, and the caller's
        // `try?` turns a full library into no results at all, silently.
        let raw = try await runScript("""
        set d to character id 31
        tell application id "com.apple.Music"
            set res to search library playlist 1 for "\(safe)"
            set total to count of res
            set out to ""
            set got to 0
            repeat with i from 1 to total
                if got is greater than or equal to 25 then exit repeat
                try
                    set tr to item i of res
                    set out to out & (name of tr) & d & (artist of tr) & d & ((duration of tr) as text) & d & ((database ID of tr) as text) & linefeed
                    set got to got + 1
                end try
            end repeat
            return out
        end tell
        """)
        return Self.parseSearch(raw)
    }

    func queueRequest(databaseID: Int) async throws -> LibraryTrack {
        let raw = try await runScript("""
        set d to character id 31
        tell application id "com.apple.Music"
            set pname to "\(Self.requestsPlaylist)"
            try
                set p to (first user playlist whose name is pname)
            on error
                set p to make new user playlist with properties {name:pname}
            end try
            set tr to (first track of library playlist 1 whose database ID is \(databaseID))
            duplicate tr to p
            return (name of tr) & d & (artist of tr) & d & ((duration of tr) as text) & d & "\(databaseID)"
        end tell
        """)
        guard let track = Self.parseSearch(raw).first else {
            throw SpotifyControllerError.malformedResponse
        }
        return track
    }

    func requests() async throws -> [LibraryTrack] {
        let raw = try await runScript("""
        set d to character id 31
        tell application id "com.apple.Music"
            try
                set p to (first user playlist whose name is "\(Self.requestsPlaylist)")
            on error
                return ""
            end try
            set ns to name of every track of p
            set ar to artist of every track of p
            set du to duration of every track of p
            set out to ""
            repeat with i from 1 to count of ns
                set out to out & (item i of ns) & d & (item i of ar) & d & ((item i of du) as text) & d & "0" & linefeed
            end repeat
            return out
        end tell
        """)
        return Self.parseSearch(raw)
    }

    /// `play p`, not `play track 1 of p`: the second starts the song with an
    /// empty Up Next (see `play(_:)`), so the queue stopped after the first
    /// request. Playing the playlist itself is what carries on through it.
    func playRequests() async throws {
        let raw = try await runScript("""
        tell application id "com.apple.Music"
            try
                set p to (first user playlist whose name is "\(Self.requestsPlaylist)")
            on error
                return "none"
            end try
            if (count of tracks of p) is 0 then return "none"
            play p
            return ""
        end tell
        """)
        if raw == "none" { throw LibraryError.noRequests }
    }

    func playNow(databaseID: Int) async throws {
        _ = try await runScript("""
        tell application id "com.apple.Music"
            play (first track of library playlist 1 whose database ID is \(databaseID))
            return ""
        end tell
        """)
    }

    func queueIsEditable() async -> Bool {
        let raw = try? await runScript("""
        tell application id "com.apple.Music"
            try
                return name of current playlist
            on error
                return ""
            end try
        end tell
        """)
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.requestsPlaylist
    }

    func reorderQueue(from: Int, to: Int) async throws {
        // `from` and `to` are offsets into the queue the remote shows, which
        // starts at the track now playing — so they are resolved against the
        // playing track's position here, not guessed by the caller.
        //
        // Music has no way to move a track inside a playlist: `move` takes a
        // playlist, not a track. The only way to reorder is to rebuild, and
        // only the tail from the first affected position needs it.
        //
        // Rebuilding is not enough on its own either. Up Next is snapshotted
        // when playback starts and ignores playlist edits — verified by
        // reordering mid-play and watching `next track` still follow the old
        // order. So the queue is re-seated afterwards, landing back on the
        // current track at the position it had reached.
        _ = try await runScript("""
        tell application id "com.apple.Music"
            set p to (first user playlist whose name is "\(Self.requestsPlaylist)")
            set n to count of tracks of p
            set wasPlaying to (player state as text is "playing")
            set here to 0
            set pos to 0
            try
                if name of current playlist is "\(Self.requestsPlaylist)" then
                    set pos to player position
                    set cid to database ID of current track
                    set ids to database ID of every track of p
                    repeat with i from 1 to count of ids
                        if item i of ids is cid then
                            set here to i
                            exit repeat
                        end if
                    end repeat
                end if
            end try
            if here is 0 then return ""

            set pFrom to here + 1 + \(from)
            set pTo to here + 1 + \(to)
            if pFrom > n or pTo > n or pFrom < 1 or pTo < 1 then return ""
            set low to pFrom
            if pTo < low then set low to pTo

            -- Plain integers, not track references: Music raises "Unknown
            -- object type" if you hold specifiers in a list and use them later.
            -- Indices stay valid throughout because duplicating only appends.
            set others to {}
            repeat with i from low to n
                if i is not pFrom then set end of others to i
            end repeat
            set plan to {}
            set k to 1
            set spot to pTo - low + 1
            repeat with i from 1 to (count of others) + 1
                if i is spot then
                    set end of plan to pFrom
                else
                    set end of plan to item k of others
                    set k to k + 1
                end if
            end repeat

            repeat with idx in plan
                duplicate track idx of p to p
            end repeat
            repeat with i from n to low by -1
                delete track i of p
            end repeat

            if wasPlaying then
                play p
                if here > 1 then
                    repeat (here - 1) times
                        next track
                    end repeat
                end if
                try
                    set player position to pos
                end try
            end if
            return ""
        end tell
        """)
    }

    func volume() async -> Int {
        let raw = try? await runScript("""
        tell application id "com.apple.Music"
            return (sound volume as text)
        end tell
        """)
        return Int(raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 100
    }

    func setVolume(_ value: Int) async {
        let clamped = min(100, max(0, value))
        _ = try? await runScript("""
        tell application id "com.apple.Music"
            set sound volume to \(clamped)
            return ""
        end tell
        """)
    }

    private static func parseSearch(_ raw: String) -> [LibraryTrack] {
        raw.components(separatedBy: .newlines).compactMap { line in
            let f = line.components(separatedBy: "\u{1F}")
            guard f.count >= 4, !f[0].isEmpty else { return nil }
            return LibraryTrack(id: f[3], name: f[0], artist: f[1],
                                duration: Double(scripted: f[2]) ?? 0,
                                playlistIndex: nil, trackIndex: nil, uri: nil,
                                databaseID: Int(f[3]))
        }
    }

    private static func parseTracks(_ raw: String, playlistIndex: Int?) -> [LibraryTrack] {
        raw.components(separatedBy: .newlines)
            .enumerated()
            .compactMap { offset, line in
                let fields = line.components(separatedBy: "\u{1F}")
                guard fields.count >= 3, !fields[0].isEmpty else { return nil }
                return LibraryTrack(id: "\(playlistIndex ?? 0):\(offset + 1):\(fields[0])",
                                    name: fields[0],
                                    artist: fields[1],
                                    duration: Double(scripted: fields[2]) ?? 0,
                                    playlistIndex: playlistIndex,
                                    trackIndex: playlistIndex == nil ? nil : offset + 1,
                                    uri: nil,
                                    databaseID: fields.count > 3 ? Int(fields[3]) : nil)
            }
    }
}

// MARK: - Spotify

/// Spotify's scripting dictionary has no library, so the library comes from the
/// Web API once you have signed in (see `SpotifyAccount`), and playback still
/// goes through the desktop app by URI — which needs no Premium, unlike the Web
/// API's own playback endpoints.
extension SpotifyController: MusicBrowser {
    var canBrowseLibrary: Bool { SpotifyAccount.isSignedIn }
    var canTakeRequests: Bool { false }

    func playlists() async throws -> [LibraryPlaylist] {
        try await SpotifyAccount.shared.playlists().map { LibraryPlaylist(index: $0.index, name: $0.name) }
    }

    func tracks(in playlist: LibraryPlaylist) async throws -> [LibraryTrack] {
        let (tracks, context) = try await SpotifyAccount.shared.tracks(inPlaylist: playlist.index)
        return tracks.enumerated().map { offset, track in
            LibraryTrack(id: "\(playlist.index)-\(offset)-\(track.uri)", name: track.name,
                         artist: track.artist, duration: track.duration,
                         playlistIndex: playlist.index, trackIndex: offset + 1,
                         uri: track.uri, contextURI: context)
        }
    }

    func upNext(limit: Int) async throws -> UpNext? {
        guard SpotifyAccount.isSignedIn,
              let tracks = try await SpotifyAccount.shared.queue(limit: limit) else { return nil }
        return UpNext(playlistName: "Spotify",
                      tracks: tracks.enumerated().map { offset, track in
                          LibraryTrack(id: "queue-\(offset)-\(track.uri)", name: track.name,
                                       artist: track.artist, duration: track.duration,
                                       playlistIndex: nil, trackIndex: nil, uri: track.uri)
                      })
    }

    /// Playlist covers come as URLs from the Web API. The probe `LibraryModel`
    /// sends for a cover is the playlist's first track.
    func artwork(for track: LibraryTrack) async -> Data? {
        guard let index = track.playlistIndex,
              let url = await SpotifyAccount.shared.coverURL(forPlaylist: index) else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    func currentArtwork() async -> Data? { nil }   // Spotify gives a URL instead

    /// Searches all of Spotify, not just your library — and unlike Apple Music's
    /// catalogue, anything found here plays straight away by URI. Uses the
    /// client-credentials token, so it works whether or not you have signed in.
    func searchLibrary(_ query: String) async throws -> [LibraryTrack] {
        try await SpotifyAPI.shared.search(query).map { hit in
            LibraryTrack(id: "search-\(hit.uri)", name: hit.name, artist: hit.artist,
                         duration: hit.duration, playlistIndex: nil, trackIndex: nil, uri: hit.uri)
        }
    }
    func requests() async throws -> [LibraryTrack] { [] }
    func queueRequest(databaseID: Int) async throws -> LibraryTrack {
        throw SpotifyControllerError.notRunning
    }
    func playRequests() async throws {}
    func playNow(databaseID: Int) async throws {}
    func queueIsEditable() async -> Bool { false }
    func reorderQueue(from: Int, to: Int) async throws {}
    func volume() async -> Int { await soundVolume() ?? 100 }
    func setVolume(_ value: Int) async { await setSoundVolume(value) }

    func play(_ track: LibraryTrack) async throws {
        guard let uri = track.uri else { return }
        try await play(uri: uri, context: track.contextURI)
    }
}
