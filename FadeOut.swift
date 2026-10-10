import Foundation

/// Ending a song early, gently: the player's volume taken down over a few
/// seconds, the song paused at silence, the volume put back, then the break
/// or the next song — rather than a hard cut. By hand (Fade Out in the
/// Controls window, ⌥⌘→, the Stream Deck, the remote), or by the time limit:
/// past it, a song fades as the line being sung ends.
///
/// The volume a fade started from is noted until it's put back, so a fade cut
/// short by quitting is put right on the next launch.
enum FadeOut {

    static let lengthKey = "fadeLength"
    /// Seconds into a song; 0 is no limit.
    static let limitKey = "songTimeLimit"
    /// The volume to put back, while a fade is under way.
    static let pendingKey = "fadeRestoreVolume"

    static let lengths: [Double] = [3, 5, 8]
    static let limits: [Double] = [0, 180, 210, 240, 270, 300, 360]

    static var length: Double {
        let value = UserDefaults.standard.double(forKey: lengthKey)
        return value > 0 ? value : 5
    }

    static var timeLimit: Double? {
        let value = UserDefaults.standard.double(forKey: limitKey)
        return value > 0 ? value : nil
    }

    /// A song only this much over the limit is left to finish.
    static let grace: Double = 20
    /// Past the limit, the longest the fade waits for a line to end.
    static let lineWait: Double = 15
    /// A line begun longer ago than this is taken as sung: fade now.
    static let lineSung: Double = 8

    static func limitTitle(_ seconds: Double) -> String {
        guard seconds > 0 else { return "Off" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The volume, from the start of a fade to its end, as the fade goes from
    /// 0 to 1: falling fastest at first and tailing off, which the ear hears
    /// as an even fade rather than loud, loud, gone.
    static func level(from start: Int, at progress: Double) -> Int {
        Int((Double(start) * pow(max(0, 1 - progress), 1.6)).rounded())
    }

    static var pendingVolume: Int? {
        get { UserDefaults.standard.object(forKey: pendingKey) as? Int }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: pendingKey) }
            else { UserDefaults.standard.removeObject(forKey: pendingKey) }
        }
    }
}
