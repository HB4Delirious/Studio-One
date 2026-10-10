import AppKit

/// A playlist in the player's library, keyed by its position. On Apple Music
/// it's addressed by `persistentID` when known: positions shift whenever a
/// playlist is added or removed, the requests playlist included.
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

    /// For looking the song up ahead of time (see `Preparation`): the album,
    /// and on Apple Music the persistent ID its settings are saved under.
    var album: String? = nil
    var persistentID: String? = nil
}

struct UpNext {
    let playlistName: String
    let tracks: [LibraryTrack]      // starting at the one now playing
}

/// The library, for the players that have one to browse: Apple Music through
/// its scripting, Spotify through the Web API once signed in.
protocol MusicBrowser: AnyObject, Sendable {
    var canBrowseLibrary: Bool { get }

    func playlists() async throws -> [LibraryPlaylist]
    func tracks(in playlist: LibraryPlaylist) async throws -> [LibraryTrack]
    func upNext(limit: Int) async throws -> UpNext?

    /// A track from a playlist — with what follows it queued behind — or a
    /// search hit on its own.
    func play(_ track: LibraryTrack) async throws

    func cover(of playlist: LibraryPlaylist) async -> Data?

    /// The playing song's cover, for players that give image data rather
    /// than a URL (Apple Music). It also tints the whole app.
    func currentArtwork() async -> Data?

    /// Apple Music: the host's own library, since its scripting can't reach
    /// the catalogue. Spotify: all of Spotify.
    func searchLibrary(_ query: String) async throws -> [LibraryTrack]

    /// The song after the one playing, with what it needs to be played again
    /// later within its playlist — for coming back from house music.
    func resumePoint() async -> LibraryTrack?

    /// The player's output volume, 0–100.
    func volume() async -> Int
    /// Nil when it couldn't be read, rather than a guess.
    func readVolume() async -> Int?
    func setVolume(_ value: Int) async
}

/// What the request line needs besides browsing: a playlist guests add to,
/// that the host can start and reorder from the remote. Only Apple Music has
/// one it can write to.
protocol RequestQueue: MusicBrowser {
    /// Appends to the requests playlist, creating it if needed, and returns
    /// what was added for the guest's confirmation.
    func queueRequest(databaseID: Int) async throws -> LibraryTrack

    /// Plays the requests playlist as a playlist — which is what gives Music
    /// an Up Next that follows it.
    func playRequests() async throws

    func playNow(databaseID: Int) async throws

    /// Whether the queue showing is the requests playlist. Anything else is
    /// one of the host's own playlists, not to be rearranged from a phone.
    func queueIsEditable() async -> Bool

    /// Moves a track, by offsets into the queue as the remote shows it.
    func reorderQueue(from: Int, to: Int) async throws
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

/// Scripts read properties in bulk (`name of every track of p`), never per
/// track in a loop: each crossing of the Apple Event boundary costs, and on a
/// 51-track playlist that's 0.18 s against 2.71 s.
extension AppleMusicController: MusicBrowser {

    var canBrowseLibrary: Bool { true }

    func playlists() async throws -> [LibraryPlaylist] {
        // No track counts: they make listing the playlists five times slower.
        let raw = try await scripts.text("""
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
        let raw = try await scripts.text("""
        set d to character id 31
        tell application id "com.apple.Music"
            set p to \(reference)
            set ns to name of every track of p
            set ar to artist of every track of p
            set du to duration of every track of p
            set di to database ID of every track of p
            set al to album of every track of p
            set pids to persistent ID of every track of p
            set out to ""
            repeat with i from 1 to count of ns
                set out to out & (item i of ns) & d & (item i of ar) & d & ((item i of du) as text) & d & (item i of di) & d & (item i of al) & d & (item i of pids) & linefeed
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
        // `current playlist` exists only while something plays; asking when
        // stopped is an error that just means "nothing queued". The slice is
        // taken inside the script, since a playlist can hold thousands.
        let raw = try await scripts.text("""
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

    /// How far into a playlist `play(_:)` will skip to reach a track (29
    /// skips take about 0.9 s). Deeper, it starts on its own, with no queue.
    private static let skipLimit = 40

    func play(_ track: LibraryTrack) async throws {
        guard let index = track.trackIndex,
              let reference = Self.playlistReference(index: track.playlistIndex, id: track.playlistID) else {
            // A search hit: no playlist to play it within.
            if let id = track.databaseID { try await playNow(databaseID: id) }
            return
        }

        // `play user playlist` queues the playlist but always starts at track
        // 1; `play track N of …` starts at N with nothing queued after it. So
        // near the top, the playlist is played and skipped through inside
        // Music. The track is found by database ID when played — its position
        // is only a fallback, in case the playlist changed since it was read.
        let wanted = track.databaseID.map(String.init) ?? "0"
        try await scripts.run("""
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

    /// The first track's cover; failing that, a 2×2 of the first four covers
    /// among the first dozen tracks, or the one found. `data of artwork`, not
    /// `raw data`, which streaming tracks ("shared tracks") refuse. One short
    /// Apple Event per track rather than one long script: they share the
    /// player's queue with the poll and the transport, which get in between.
    func cover(of playlist: LibraryPlaylist) async -> Data? {
        guard let reference = Self.playlistReference(index: playlist.index, id: playlist.persistentID) else { return nil }
        if let first = await artwork(track: 1, of: reference) { return first }
        let raw = try? await scripts.text("""
        tell application id "com.apple.Music"
            return (count of tracks of \(reference)) as text
        end tell
        """)
        let count = min(12, Int(raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0)
        var covers: [Data] = []
        if count >= 2 {
            for index in 2...count where covers.count < 4 {
                if let data = await artwork(track: index, of: reference) { covers.append(data) }
            }
        }
        if covers.count >= 4, let mosaic = NSImage.mosaic(covers.prefix(4).compactMap(NSImage.init(data:)), side: 600) {
            return mosaic
        }
        return covers.first
    }

    private func artwork(track index: Int, of reference: String) async -> Data? {
        try? await scripts.data("""
        tell application id "com.apple.Music"
            return data of artwork 1 of track \(index) of \(reference)
        end tell
        """)
    }

    func resumePoint() async -> LibraryTrack? {
        // The current playlist's persistent ID and the next track's place and
        // identity. Nothing when nothing is next, or the library itself plays.
        let raw = try? await scripts.text("""
        set d to character id 31
        tell application id "com.apple.Music"
            try
                set p to current playlist
                set cid to database ID of current track
                set ids to database ID of every track of p
                set idx to 0
                repeat with i from 1 to count of ids
                    if item i of ids is cid then
                        set idx to i
                        exit repeat
                    end if
                end repeat
                if idx is 0 or idx ≥ (count of ids) then return ""
                set t to track (idx + 1) of p
                return (persistent ID of p) & d & ((idx + 1) as text) & d & ((database ID of t) as text) & d & (name of t) & d & (artist of t) & d & ((duration of t) as text)
            on error
                return ""
            end try
        end tell
        """)
        let fields = (raw ?? "").components(separatedBy: "\u{1F}")
        guard fields.count == 6, let index = Int(fields[1]), let id = Int(fields[2]) else { return nil }
        return LibraryTrack(id: "resume-\(id)", name: fields[3], artist: fields[4],
                            duration: Double(scripted: fields[5]) ?? 0,
                            playlistIndex: nil, trackIndex: index, uri: nil,
                            databaseID: id, playlistID: fields[0])
    }

    /// The requests playlist's persistent ID, for playing a new request within it.
    func requestsPlaylistID() async -> String? {
        let raw = try? await scripts.text("""
        tell application id "com.apple.Music"
            try
                return persistent ID of (first user playlist whose name is "\(Self.requestsPlaylist)")
            on error
                return ""
            end try
        end tell
        """)
        let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    /// Songs in the requests playlist; nil when there isn't one yet.
    func requestCount() async -> Int? {
        let raw = try? await scripts.text("""
        tell application id "com.apple.Music"
            try
                return (count of tracks of (first user playlist whose name is "\(Self.requestsPlaylist)")) as text
            on error
                return ""
            end try
        end tell
        """)
        return raw.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func currentArtwork() async -> Data? {
        try? await scripts.data("""
        tell application id "com.apple.Music"
            return data of artwork 1 of current track
        end tell
        """)
    }

    static let requestsPlaylist = "Studio One Requests"

    func searchLibrary(_ query: String) async throws -> [LibraryTrack] {
        // From the network, so anything that could end the string literal is
        // stripped rather than escaped.
        let safe = query.replacingOccurrences(of: "\"", with: " ")
                        .replacingOccurrences(of: "\\", with: " ")
                        .prefix(80)
        // A `try` per row: Music's search index can return a track that no
        // longer exists (until Music restarts), and reading it fails -1700 —
        // which would otherwise take every result down with it.
        let raw = try await scripts.text("""
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

    func volume() async -> Int { await readVolume() ?? 100 }

    func readVolume() async -> Int? {
        let raw = try? await scripts.text("""
        tell application id "com.apple.Music"
            return (sound volume as text)
        end tell
        """)
        return Int(raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    func setVolume(_ value: Int) async {
        let clamped = min(100, max(0, value))
        _ = try? await scripts.text("""
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
                                    databaseID: fields.count > 3 ? Int(fields[3]) : nil,
                                    album: fields.count > 4 ? fields[4] : nil,
                                    persistentID: fields.count > 5 ? fields[5] : nil)
            }
    }
}

extension AppleMusicController: RequestQueue {

    func queueRequest(databaseID: Int) async throws -> LibraryTrack {
        let raw = try await scripts.text("""
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
            throw PlayerError.malformedResponse
        }
        return track
    }

    /// `play p`, not `play track 1 of p`, which leaves nothing queued after
    /// the first request (see `play(_:)`).
    func playRequests() async throws {
        let raw = try await scripts.text("""
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
        try await scripts.run("""
        tell application id "com.apple.Music"
            play (first track of library playlist 1 whose database ID is \(databaseID))
            return ""
        end tell
        """)
    }

    func queueIsEditable() async -> Bool {
        let raw = try? await scripts.text("""
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
        // `from` and `to` count from the playing track, as the remote shows
        // the queue, so they're resolved against its position here. Music
        // can't move a track within a playlist, so the tail from the first
        // affected position is rebuilt; and since Up Next ignores edits made
        // during playback, the playlist is then replayed from the same track
        // and position.
        try await scripts.run("""
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

            -- Indices, not track references, which Music can't use later
            -- ("Unknown object type"). Duplicating only appends, so they hold.
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
}

// MARK: - Spotify

/// Spotify's library comes from the Web API once signed in (`SpotifyAccount`);
/// playback goes through the desktop app by URI, which unlike the Web API's
/// playback endpoints needs no Premium.
extension SpotifyController: MusicBrowser {
    var canBrowseLibrary: Bool { SpotifyAccount.isSignedIn }

    func playlists() async throws -> [LibraryPlaylist] {
        try await SpotifyAccount.shared.playlists().map { LibraryPlaylist(index: $0.index, name: $0.name) }
    }

    func tracks(in playlist: LibraryPlaylist) async throws -> [LibraryTrack] {
        let (tracks, context) = try await SpotifyAccount.shared.tracks(inPlaylist: playlist.index)
        return tracks.enumerated().map { offset, track in
            LibraryTrack(id: "\(playlist.index)-\(offset)-\(track.uri)", name: track.name,
                         artist: track.artist, duration: track.duration,
                         playlistIndex: playlist.index, trackIndex: offset + 1,
                         uri: track.uri, contextURI: context, album: track.album)
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

    func cover(of playlist: LibraryPlaylist) async -> Data? {
        guard let url = await SpotifyAccount.shared.coverURL(forPlaylist: playlist.index) else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    func currentArtwork() async -> Data? { nil }   // Spotify gives a URL instead

    /// All of Spotify, signed in or not (it uses the client-credentials
    /// token), and anything found plays straight away.
    func searchLibrary(_ query: String) async throws -> [LibraryTrack] {
        try await SpotifyAPI.shared.search(query).map { hit in
            LibraryTrack(id: "search-\(hit.uri)", name: hit.name, artist: hit.artist,
                         duration: hit.duration, playlistIndex: nil, trackIndex: nil, uri: hit.uri)
        }
    }
    func volume() async -> Int { await soundVolume() ?? 100 }
    func readVolume() async -> Int? { await soundVolume() }

    /// From the Web API, so signed in only: the next in the queue, played
    /// within the playlist playing.
    func resumePoint() async -> LibraryTrack? {
        guard SpotifyAccount.isSignedIn,
              let queue = try? await SpotifyAccount.shared.queue(limit: 1), queue.count > 1 else { return nil }
        let next = queue[1]
        let context = try? await SpotifyAccount.shared.playingContext()
        return LibraryTrack(id: "resume-\(next.uri)", name: next.name, artist: next.artist,
                            duration: next.duration, playlistIndex: nil, trackIndex: nil,
                            uri: next.uri, contextURI: context ?? nil)
    }
    func setVolume(_ value: Int) async { await setSoundVolume(value) }

    func play(_ track: LibraryTrack) async throws {
        guard let uri = track.uri else { return }
        try await play(uri: uri, context: track.contextURI)
    }
}
