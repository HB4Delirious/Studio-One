import Foundation

/// A break between songs, the way a karaoke night runs: as a song ends,
/// Studio One pauses before the next, and the lyrics screen shows who's up
/// next and the code to request — and, with the applause meter on, the room's
/// cheer for the song just sung (see `Applause`). Play starts the next song;
/// so does the break's own timer, when it has one.
///
/// Only a song that plays to its end starts one. Next, Previous or a pick in
/// the library moves on as it always has.
enum BreakMode: String, CaseIterable, Identifiable {
    case off
    case seconds15
    case seconds30
    case seconds60
    case untilPlay

    static let defaultsKey = "breakBetweenSongs"

    static var current: BreakMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(BreakMode.init(rawValue:)) ?? .off
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:       return "Off"
        case .seconds15: return "15 s"
        case .seconds30: return "30 s"
        case .seconds60: return "1 min"
        case .untilPlay: return "Until Play"
        }
    }

    /// How long the break lasts; nil waits for Play.
    var seconds: Double? {
        switch self {
        case .off, .untilPlay: return nil
        case .seconds15:       return 15
        case .seconds30:       return 30
        case .seconds60:       return 60
        }
    }
}

/// The break under way: the song just sung, and when the next starts.
struct Intermission: Equatable {
    let endedName: String
    let endedArtist: String
    let endedURI: String
    /// Who sang it, when a guest requested it.
    let singer: String?
    let started: Date
    /// Nil when it waits for Play.
    var endsAt: Date?
}
