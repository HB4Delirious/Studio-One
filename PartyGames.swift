import Foundation

extension Notification.Name {
    /// The applause meter scored a song: "name", "artist", "score".
    static let applauseScored = Notification.Name("StudioOne.applauseScored")
}

/// Games for the room, started from the Controls window's Games button:
///
/// - **Song battle**: the song playing against the next; each break's
///   applause scores its singer, and the second break names the winner.
/// - **Finish the lyric**: later in the song, the end of a few lines goes
///   blank on the screen and on phones, for the singer to finish from memory.
/// - **Name that tune**: the song's title and lyrics are hidden; guests guess
///   on their phones, and the first right answer wins.
@MainActor
final class PartyGames: ObservableObject {
    static let shared = PartyGames()

    // MARK: - Song battle

    struct Contender: Equatable {
        let name: String
        let artist: String
        var singer: String?
        var score: Int?

        var who: String { singer ?? name }
    }

    struct Battle: Equatable {
        var first: Contender
        var second: Contender
        var isDecided: Bool { first.score != nil && second.score != nil }
        /// Nil for a tie, or before it's decided.
        var winner: Contender? {
            guard let a = first.score, let b = second.score, a != b else { return nil }
            return a > b ? first : second
        }
    }

    @Published private(set) var battle: Battle?

    /// This song against the next. Needs the break and the applause meter,
    /// which do the judging.
    func startBattle(current: PlayerTrack, next: LibraryTrack) {
        let requests = RequestServer.shared
        battle = Battle(
            first: Contender(name: current.name, artist: current.artist,
                             singer: requests.requester(name: current.name, artist: current.artist)),
            second: Contender(name: next.name, artist: next.artist,
                              singer: requests.requester(name: next.name, artist: next.artist)))
        Diagnostics.log("games: battle, \(current.name) against \(next.name)")
    }

    func endBattle() { battle = nil }

    private func scored(name: String, artist: String, score: Int) {
        guard var battle else { return }
        let key = SongInfo.key(name, artist)
        if battle.first.score == nil, SongInfo.key(battle.first.name, battle.first.artist) == key {
            battle.first.score = score
        } else if battle.second.score == nil, SongInfo.key(battle.second.name, battle.second.artist) == key {
            battle.second.score = score
        } else {
            return
        }
        self.battle = battle
        Diagnostics.log("games: battle score \(score) for \(name)")
    }

    // MARK: - Finish the lyric

    /// Line ID → the first hidden lead word, for the song in `finishURI`.
    @Published private(set) var finishMasks: [Int: Int] = [:]
    private(set) var finishURI: String?

    /// Up to three lines in the song's second half, at least four words long
    /// and spread out, lose their second half.
    func startFinishTheLyric(uri: String, lines: [LyricLine]) {
        let sung = lines.filter { !$0.isBlank && $0.leadWords.count >= 4 }
        guard let last = sung.last else { return }
        let half = (sung.first?.time ?? 0) + (last.time - (sung.first?.time ?? 0)) / 2
        let later = sung.filter { $0.time >= half }
        var picked: [LyricLine] = []
        let stride = max(3, later.count / 3)
        for (index, line) in later.enumerated() where index % stride == stride / 2 && picked.count < 3 {
            picked.append(line)
        }
        finishMasks = Dictionary(uniqueKeysWithValues: picked.map { ($0.id, $0.leadWords.count / 2) })
        finishURI = uri
        Diagnostics.log("games: finish the lyric, \(picked.count) lines")
    }

    func endFinishTheLyric() {
        finishMasks = [:]
        finishURI = nil
    }

    /// The mask for a line of the song playing, while it's still to be sung.
    func maskFrom(_ line: LyricLine, uri: String?, at position: Double) -> Int? {
        guard uri == finishURI, position < line.voicedEnd else { return nil }
        return finishMasks[line.id]
    }

    static func masked(_ line: LyricLine, from index: Int) -> String {
        line.leadWords.map { $0.id >= index ? String(repeating: "_", count: max(3, $0.text.count)) : $0.text }
            .joined(separator: " ")
    }

    // MARK: - Name that tune

    struct Tune: Equatable {
        let uri: String
        let answer: String
        let artist: String
        let started: Date
        var guesses = 0
        var winner: String?
        var seconds: Int?
        var revealed = false
    }

    @Published private(set) var tune: Tune?

    func startNameThatTune(_ track: PlayerTrack) {
        tune = Tune(uri: track.uri, answer: track.name, artist: track.artist, started: Date())
        Diagnostics.log("games: name that tune, \(track.name)")
    }

    func reveal() {
        guard var tune, !tune.revealed else { return }
        tune.revealed = true
        self.tune = tune
        // The screen shows the answer a while, then the song carries on.
        let uri = tune.uri
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.tune?.uri == uri { self?.tune = nil }
        }
    }

    func endNameThatTune() { tune = nil }

    /// A guest's guess: right, wrong, or too late.
    func guess(_ text: String, from nick: String) -> (correct: Bool, winner: String?) {
        guard var tune, !tune.revealed else { return (false, self.tune?.winner) }
        tune.guesses += 1
        let correct = Self.matches(text, tune.answer)
        if correct {
            tune.winner = nick.isEmpty ? "Someone" : nick
            tune.seconds = Int(Date().timeIntervalSince(tune.started).rounded())
            Diagnostics.log("games: \(tune.winner ?? "") named the tune in \(tune.seconds ?? 0) s")
        }
        self.tune = tune
        if correct { reveal() }
        return (correct, tune.winner)
    }

    /// Generous: versions and credits ignored, small typos forgiven, and a
    /// long title's main words enough.
    nonisolated static func matches(_ guess: String, _ title: String) -> Bool {
        let wanted = plain(LyricsProvider.normalizeTitle(title))
        let given = plain(guess)
        guard !wanted.isEmpty, !given.isEmpty else { return false }
        if given == wanted { return true }
        let wantedWords = Set(wanted.split(separator: " "))
        let givenWords = Set(given.split(separator: " "))
        if wantedWords.isSubset(of: givenWords) { return true }
        if wantedWords.count >= 3,
           Double(wantedWords.intersection(givenWords).count) / Double(wantedWords.count) >= 0.75 { return true }
        // A typo a word's worth of letters can't hide in: none for short
        // titles, one per eight letters for longer ones.
        return wanted.count >= 8 && distance(given, wanted) <= wanted.count / 8
    }

    nonisolated private static func plain(_ text: String) -> String {
        let spaced = String(text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .map { $0.isLetter || $0.isNumber ? $0 : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    nonisolated private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.prefix(80)), b = Array(b.prefix(80))
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Song changes

    private init() {
        NotificationCenter.default.addObserver(forName: .applauseScored, object: nil, queue: .main) { note in
            guard let name = note.userInfo?["name"] as? String, let artist = note.userInfo?["artist"] as? String,
                  let score = note.userInfo?["score"] as? Int else { return }
            MainActor.assumeIsolated { PartyGames.shared.scored(name: name, artist: artist, score: score) }
        }
    }

    /// A new song: games for the last one end, and a decided battle is over
    /// once someone else is singing.
    func songChanged(to track: PlayerTrack?) {
        if let finishURI, finishURI != track?.uri { endFinishTheLyric() }
        if let tune, tune.uri != track?.uri { endNameThatTune() }
        if let battle, battle.isDecided, let track,
           SongInfo.key(track.name, track.artist) != SongInfo.key(battle.second.name, battle.second.artist) {
            endBattle()
        }
    }
}
