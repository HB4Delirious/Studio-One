import SwiftUI

/// How hard a song is to sing, for guests choosing one and for the host.
enum Difficulty: Int, Codable, CaseIterable {
    case easy = 1, medium, hard

    var title: String {
        switch self {
        case .easy:   return "Easy"
        case .medium: return "Medium"
        case .hard:   return "Hard"
        }
    }

    var color: Color {
        switch self {
        case .easy:   return .green
        case .medium: return Theme.sung
        case .hard:   return Color(red: 0.91, green: 0.22, blue: 0.56)
        }
    }

    /// From timed lyrics and the tempo: how fast the words come (most of it),
    /// how long the longest notes are held, and how quick the song is. Nil
    /// without enough timed lines to judge.
    static func rate(lines: [LyricLine], tempo: Double?) -> Difficulty? {
        let sung = lines.filter { !$0.isBlank }
        guard sung.count >= 4 else { return nil }
        var words = 0
        var seconds = 0.0
        var longestHold = 0.0
        for line in sung {
            let count = max(1, line.words.isEmpty
                            ? line.text.split(whereSeparator: \.isWhitespace).count
                            : line.words.count)
            let voiced = max(0.3, line.voicedEnd - line.time)
            words += count
            seconds += voiced
            longestHold = max(longestHold, voiced / Double(count))
        }
        let pace = Double(words) / max(1, seconds)                  // words a second
        func scale(_ value: Double, _ from: Double, _ to: Double) -> Double {
            min(1, max(0, (value - from) / (to - from)))
        }
        let score = scale(pace, 1.2, 3.6) * 0.6
            + scale(longestHold, 0.9, 2.7) * 0.25
            + scale(tempo ?? 100, 90, 170) * 0.15
        return score < 0.25 ? .easy : score < 0.55 ? .medium : .hard
    }
}

/// What's kept about a song beyond its settings: how hard it is, worked out
/// when its lyrics are known, and the host's own note ("starts quiet", "great
/// duet") — never shown to guests. Keyed by title and artist, so a song is
/// the same song from either player and from the request line's search.
enum SongInfo {
    private static let difficulties = PerSongSetting<Int>("songDifficulty")
    private static let notes = PerSongSetting<String>("songNotes")

    static func key(_ name: String, _ artist: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces) + "|"
            + artist.lowercased().trimmingCharacters(in: .whitespaces)
    }

    static func difficulty(_ name: String, _ artist: String) -> Difficulty? {
        difficulties[key(name, artist)].flatMap(Difficulty.init(rawValue:))
    }

    static func setDifficulty(_ difficulty: Difficulty?, _ name: String, _ artist: String) {
        difficulties[key(name, artist)] = difficulty?.rawValue
    }

    static func note(_ name: String, _ artist: String) -> String? {
        notes[key(name, artist)]
    }

    static func setNote(_ note: String, _ name: String, _ artist: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[key(name, artist)] = trimmed.isEmpty ? nil : trimmed
    }
}

/// "Easy", "Medium" or "Hard", as a small coloured capsule.
struct DifficultyChip: View {
    let difficulty: Difficulty
    var compact = false

    var body: some View {
        Text(compact ? String(difficulty.title.prefix(1)) : difficulty.title)
            .font(.system(size: compact ? 9.5 : 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(difficulty.color)
            .padding(.horizontal, compact ? 5 : 7).padding(.vertical, 1.5)
            .background(Capsule().fill(difficulty.color.opacity(0.16)))
            .help("\(difficulty.title) to sing — from how fast the words come, the longest held notes and the tempo")
    }
}
