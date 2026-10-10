import Foundation

struct LyricWord: Hashable {
    let time: Double
    let text: String
    /// Words that sat inside parentheses — backing vocals and ad-libs rather
    /// than the lead line.
    var isAside: Bool = false
}

/// A word of the lead line, carrying its index into `words` so timing still
/// resolves after the asides are filtered out.
struct LyricLeadWord: Identifiable, Hashable {
    let id: Int
    let text: String
}

/// A parenthetical phrase — backing vocals — with its own timing.
struct LyricAside: Identifiable, Hashable {
    let id: Int
    let text: String
    let start: Double
    let end: Double
}

/// Who sings a line of a duet, from a marker at the line's start — the
/// karaoke files' "F:" and "M:", or "V1:"/"V2:", "P1:"/"P2:", and "D:" or
/// "Both:" for the two together.
enum LyricPart: Int, Hashable, Codable {
    case first = 1, second = 2, both = 3
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
    /// Populated only for "enhanced LRC" files that carry `<mm:ss.xx>` word tags.
    let words: [LyricWord]
    /// Start of the next line — used to pace the sweep on plain LRC.
    var end: Double

    /// Worked out once at parse time: the stage redraws up to 120 times a
    /// second, and these never change within a line.
    var leadWords: [LyricLeadWord] = []
    var asides: [LyricAside] = []
    /// When the singing stops — for estimated words, earlier than `end`, which
    /// runs on through any silence to the next line.
    var voicedEnd: Double
    /// The duet part, when the lyrics mark one; carried on from the last
    /// marker to lines without one.
    var part: LyricPart?
    /// The marker as written, for the label beside the line: "F", "M", "1",
    /// "Both".
    var partLabel: String?

    var duration: Double { max(0.2, end - time) }

    /// Lines made entirely of parenthetical backing vocals have no lead to show.
    var hasLead: Bool { !leadWords.isEmpty }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Which word is being sung at `position`, and how far through it we are.
    /// nil before the line starts, or when the line carries no word breakdown.
    func wordState(at position: Double) -> (index: Int, fraction: Double)? {
        guard !words.isEmpty, position >= time else { return nil }
        guard position < voicedEnd else { return (words.count - 1, 1) }

        for index in words.indices.reversed() where position >= words[index].time {
            let wordEnd = index + 1 < words.count ? words[index + 1].time : voicedEnd
            let span = max(0.05, wordEnd - words[index].time)

            // Finish slightly before the next word: at frame rate the last frame
            // of a short word lands near 0.95, and the rest would pop in.
            let lead = min(0.04, span * 0.08)
            let fraction = (position - words[index].time) / max(0.05, span - lead)
            return (index, min(1, max(0, fraction)))
        }
        return (0, 0)
    }

    /// 0...1 sweep across the line at the given playback position.
    func progress(at position: Double) -> Double {
        guard position > time else { return 0 }
        guard position < end else { return 1 }

        if words.count > 1 {
            // Word-timed: find the word we're inside and interpolate across it,
            // then convert to a fraction of the line's character count.
            let totalChars = max(1, words.reduce(0) { $0 + $1.text.count })
            var consumed = 0
            for (index, word) in words.enumerated() {
                let wordEnd = index + 1 < words.count ? words[index + 1].time : end
                if position < word.time { break }
                if position < wordEnd {
                    let within = (position - word.time) / max(0.05, wordEnd - word.time)
                    return Double(consumed) / Double(totalChars)
                        + within * Double(word.text.count) / Double(totalChars)
                }
                consumed += word.text.count
            }
            return Double(consumed) / Double(totalChars)
        }

        return (position - time) / duration
    }
}

enum LRCParser {

    /// Where the beat grid sits, estimated from where the lines start. Lines
    /// tend to begin on or near a beat, so the circular mean of their phases
    /// is a better estimate than any one line, and gives a grid that never
    /// jumps.
    static func beatOffset(lines: [LyricLine], bpm: Double) -> Double {
        guard bpm >= 40, bpm <= 250 else { return 0 }
        let beat = 60.0 / bpm

        let starts = lines.filter { !$0.isBlank }.map(\.time)
        guard starts.count >= 4 else { return 0 }

        // As angles: across the wrap, 0.98 and 0.02 are neighbours.
        var x = 0.0, y = 0.0
        for start in starts {
            let angle = 2 * Double.pi * (start.truncatingRemainder(dividingBy: beat) / beat)
            x += cos(angle)
            y += sin(angle)
        }
        guard x != 0 || y != 0 else { return 0 }

        var mean = atan2(y, x)
        if mean < 0 { mean += 2 * Double.pi }
        return mean / (2 * Double.pi) * beat
    }

    private static let timeTag = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let wordTag = try! NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>"#)
    private static let offsetTag = try! NSRegularExpression(
        pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#, options: [.caseInsensitive])

    static func parse(_ lrc: String) -> [LyricLine] {
        var offsetSeconds: Double = 0
        var collected: [(time: Double, text: String, words: [LyricWord],
                         part: (LyricPart, String)?)] = []
        // The part runs on from its marker until the next.
        var currentPart: (LyricPart, String)?

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)

            // [offset:+250] shifts the whole file. Positive means "show lyrics earlier".
            if let match = offsetTag.firstMatch(in: line, range: whole),
               let ms = Double(ns.substring(with: match.range(at: 1))) {
                offsetSeconds = ms / 1000
                continue
            }

            // A line may carry several timestamps for the same words —
            // "[00:12.00][01:45.00]", with or without spaces. Only leading
            // tags count; a later "[12:30]" is part of the lyric.
            var times: [Double] = []
            var cursor = 0
            for match in timeTag.matches(in: line, range: whole) {
                while cursor < ns.length, ns.character(at: cursor) == 0x20 { cursor += 1 }
                guard match.range.location == cursor else { break }
                cursor = match.range.location + match.range.length
                times.append(seconds(
                    minutes: ns.substring(with: match.range(at: 1)),
                    seconds: ns.substring(with: match.range(at: 2))))
            }
            guard !times.isEmpty else { continue }  // metadata tag like [ar:...]

            var body = ns.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            if let (part, label, rest) = duetMarker(in: body) {
                currentPart = (part, label)
                body = rest
            }
            let (text, words) = extractWords(from: body, lineTime: times[0])
            for time in times {
                collected.append((time, text, words, text.isEmpty ? nil : currentPart))
            }
        }

        // Stable, so lines stamped with the same time keep the file's order.
        collected = collected.enumerated()
            .sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }
            .map(\.element)

        var lines: [LyricLine] = []
        lines.reserveCapacity(collected.count)
        for (index, item) in collected.enumerated() {
            let start = max(0, item.time - offsetSeconds)
            let next = index + 1 < collected.count
                ? max(0, collected[index + 1].time - offsetSeconds)
                : start + 6
            let lineEnd = max(start + 0.2, next)
            let tagged = item.words.map {
                LyricWord(time: max(0, $0.time - offsetSeconds), text: $0.text)
            }
            // Enhanced LRC gives us real word onsets. Everything else gets
            // estimated ones, so the highlight still advances word by word.
            let breakdown = tagged.isEmpty
                ? estimateWords(text: item.text, from: start, to: lineEnd)
                : (words: markAsides(tagged), voicedEnd: lineEnd)
            let marked = breakdown.words
            let voiced = min(lineEnd, max(start + 0.2, breakdown.voicedEnd))

            lines.append(LyricLine(
                id: index,
                time: start,
                text: item.text,
                words: marked,
                end: lineEnd,
                leadWords: leadWords(from: marked),
                asides: asides(from: marked, voicedEnd: voiced),
                voicedEnd: voiced,
                part: item.part?.0,
                partLabel: item.part?.1))
        }
        return lines
    }

    private static let duetTag = try! NSRegularExpression(
        pattern: #"^(F|M|D|V[12]|P[12]|BOTH|ALL|DUET)\s*:\s*"#, options: [.caseInsensitive])

    /// A duet marker at the start of a line's words, and the words after it.
    static func duetMarker(in body: String) -> (LyricPart, String, String)? {
        let ns = body as NSString
        guard let match = duetTag.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let tag = ns.substring(with: match.range(at: 1)).uppercased()
        let rest = ns.substring(from: match.range.location + match.range.length)
        switch tag {
        case "F":        return (.first, "F", rest)
        case "M":        return (.second, "M", rest)
        case "V1", "P1": return (.first, "1", rest)
        case "V2", "P2": return (.second, "2", rest)
        default:         return (.both, "Both", rest)
        }
    }

    /// Splits `body` into plain text plus word timings, if the file uses `<mm:ss.xx>` tags.
    private static func extractWords(from body: String, lineTime: Double) -> (String, [LyricWord]) {
        let ns = body as NSString
        let matches = wordTag.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (body, []) }

        var words: [LyricWord] = []
        // A first word may go untagged, starting at the line's own time:
        // "[00:12.00]Hello <00:12.50>world".
        let untagged = ns.substring(to: matches[0].range.location)
        if !untagged.trimmingCharacters(in: .whitespaces).isEmpty {
            words.append(LyricWord(time: lineTime, text: untagged))
        }
        for (index, match) in matches.enumerated() {
            let time = seconds(
                minutes: ns.substring(with: match.range(at: 1)),
                seconds: ns.substring(with: match.range(at: 2)))
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard textEnd > textStart else { continue }
            let chunk = ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            words.append(LyricWord(time: time, text: chunk))
        }

        let plain = wordTag
            .stringByReplacingMatches(in: body, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        return (plain, words)
    }

    /// Word timings for a line-timed LRC — most of LRCLIB, which says only
    /// when each line starts. Weighted by syllables, so the highlight lingers
    /// on "shine" and skips through "in the", much closer to how a line is sung
    /// than a steady sweep. An estimate: held notes and rests still drift.
    static func estimateWords(text: String, from start: Double,
                              to end: Double) -> (words: [LyricWord], voicedEnd: Double) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return ([], start) }
        let available = max(0.2, end - start)

        // Words in brackets are backing vocals, marked so the stage can float
        // them apart from the lead line.
        var depth = 0
        var aside: [Bool] = []
        for token in tokens {
            let opens = token.filter { $0 == "(" }.count
            let closes = token.filter { $0 == ")" }.count
            aside.append(depth > 0 || opens > 0)
            depth = max(0, depth + opens - closes)
        }

        let bare = tokens.map {
            $0.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        }
        let weights = bare.map { Double(max(1, syllables(in: $0))) }

        // Asides are timed like any other word: they take real time to sing,
        // and treating them as free started the lead too early.
        //
        // `end` is the next line's start, silence included, so the span is
        // capped at a plausible sung pace; spread over a gap, the highlight
        // would crawl behind the singer.
        let total = weights.reduce(0, +)
        guard total > 0 else { return ([], start) }

        let span = min(available, total * secondsPerSyllable)
        var words: [LyricWord] = []
        words.reserveCapacity(tokens.count)
        var consumed = 0.0
        for index in tokens.indices {
            words.append(LyricWord(time: start + span * (consumed / total),
                                   text: bare[index],
                                   isAside: aside[index]))
            consumed += weights[index]
        }

        return (words, start + span)
    }

    /// The slowest pace still taken for singing rather than a gap. Across
    /// 8,192 cached lines, 8% are sung slower and have their sweep cut short
    /// (a quicker 0.33 s clips 27%); only 190 are followed by a real gap.
    private static let secondsPerSyllable = 0.50

    private static func markAsides(_ words: [LyricWord]) -> [LyricWord] {
        var depth = 0
        return words.map { word in
            let opens = word.text.filter { $0 == "(" }.count
            let closes = word.text.filter { $0 == ")" }.count
            let inside = depth > 0 || opens > 0
            depth = max(0, depth + opens - closes)

            let bare = word.text
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            return LyricWord(time: word.time, text: bare, isAside: inside)
        }
    }

    /// Lead words, trimmed, with their original indices preserved.
    private static func leadWords(from words: [LyricWord]) -> [LyricLeadWord] {
        words.enumerated().compactMap { index, word in
            guard !word.isAside else { return nil }
            let text = word.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : LyricLeadWord(id: index, text: text)
        }
    }

    /// Contiguous runs of parenthetical words become one floating phrase.
    private static func asides(from words: [LyricWord], voicedEnd: Double) -> [LyricAside] {
        var result: [LyricAside] = []
        var run: [Int] = []

        func flush() {
            defer { run = [] }
            guard let first = run.first, let last = run.last else { return }
            // Trimmed first: word-timed files keep each word's trailing
            // space, and joining those with another doubled every gap.
            let text = run.map { words[$0].text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }

            let end = last + 1 < words.count ? words[last + 1].time : voicedEnd
            result.append(LyricAside(id: result.count,
                                     text: text,
                                     start: words[first].time,
                                     end: max(words[first].time + 0.3, end)))
        }

        for index in words.indices {
            if words[index].isAside { run.append(index) } else { flush() }
        }
        flush()
        return result
    }

    /// Vowel-group count, which is a decent proxy for how long a word is held.
    private static func syllables(in word: String) -> Int {
        let vowels = Set("aeiouyAEIOUY")
        var count = 0
        var previousWasVowel = false
        for character in word {
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        // A silent final "e": "shine" is one beat.
        if count > 1, word.count > 2, word.lowercased().hasSuffix("e") { count -= 1 }
        return max(1, count)
    }

    private static func seconds(minutes: String, seconds secondsField: String) -> Double {
        // Some files use [01:23:45] with a colon before the fraction.
        let normalized = secondsField.replacingOccurrences(of: ":", with: ".")
        return (Double(minutes) ?? 0) * 60 + (Double(normalized) ?? 0)
    }
}
