import Foundation

/// Music between singers: a "house" playlist, quieter than the singing, during
/// breaks and while nothing is queued. Studio One notes the next song in the
/// queue before it starts, and plays that song when the break ends — or, with
/// nothing queued, the first request that comes in.
///
/// House music never ends a break, isn't sent to Logic, isn't kept in History
/// and doesn't show on the lyrics screen.
enum HouseMusic {
    static let enabledKey = "houseMusic"
    static let playlistKey = "houseMusicPlaylist"
    /// Percent of the singing volume.
    static let levelKey = "houseMusicLevel"
    static let duringBreaksKey = "houseMusicDuringBreaks"
    static let whenEmptyKey = "houseMusicWhenEmpty"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var level: Double {
        let value = UserDefaults.standard.double(forKey: levelKey)
        return value > 0 ? value : 40
    }
    static var duringBreaks: Bool { UserDefaults.standard.object(forKey: duringBreaksKey) as? Bool ?? true }
    static var whenEmpty: Bool { UserDefaults.standard.object(forKey: whenEmptyKey) as? Bool ?? true }

    /// The playlist chosen, matched again by persistent ID where the player
    /// has one, else by name: positions change.
    struct Choice: Codable, Hashable {
        let name: String
        let persistentID: String?

        init(_ playlist: LibraryPlaylist) {
            name = playlist.name
            persistentID = playlist.persistentID
        }

        func matches(_ playlist: LibraryPlaylist) -> Bool {
            persistentID != nil ? playlist.persistentID == persistentID : playlist.name == name
        }
    }

    static var playlist: Choice? {
        get {
            UserDefaults.standard.data(forKey: playlistKey).flatMap { try? JSONDecoder().decode(Choice.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: playlistKey)
        }
    }
}
