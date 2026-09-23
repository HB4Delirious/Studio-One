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

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
    /// Populated only for "enhanced LRC" files that carry `<mm:ss.xx>` word tags.
    let words: [LyricWord]
    /// Start of the next line — used to pace the sweep on plain LRC.
    var end: Double

    /// Precomputed at parse time. The stage rebuilds these views on every frame
    /// — up to 120 times a second — so filtering, trimming and grouping words
    /// there meant doing the same allocations continuously for a result that
    /// never changes within a line.
    var leadWords: [LyricLeadWord] = []
    var asides: [LyricAside] = []
    /// When the singing actually stops. For estimated words this lands earlier
    /// than `end`, which runs to the next line and so includes trailing silence.
    var voicedEnd: Double

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

            // Finish the sweep slightly before the next word starts. Sampling at
            // frame rate means the last frame of a short word lands around 0.95,
            // so the final sliver would otherwise snap to full in one frame
            // rather than sweeping — visible as a pop at the end of every word.
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

    /// Best-fit offset of the beat grid, estimated from where the lyric lines
    /// start.
    ///
    /// Nothing tells us where the downbeat actually falls. But lines tend to
    /// begin on or near beats, so the circular mean of every line's phase within
    /// the beat is a much better estimate than trusting any single line — and
    /// unlike re-anchoring on each line, it yields a grid that never jumps,
    /// which is what made the pulse read as offbeat.
    static func beatOffset(lines: [LyricLine], bpm: Double) -> Double {
        guard bpm >= 40, bpm <= 250 else { return 0 }
        let beat = 60.0 / bpm

        let starts = lines.filter { !$0.isBlank }.map(\.time)
        guard starts.count >= 4 else { return 0 }

        // Average the phases as angles; a plain mean would be wrong across the
        // wrap point, where 0.98 and 0.02 are neighbours rather than opposites.
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
        var collected: [(time: Double, text: String, words: [LyricWord])] = []

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

            // A line may carry several timestamps: [00:12.00][01:45.00] same words.
            // Only leading, back-to-back tags count as timestamps.
            var times: [Double] = []
            var cursor = 0
            for match in timeTag.matches(in: line, range: whole) {
                guard match.range.location == cursor else { break }
                cursor = match.range.location + match.range.length
                times.append(seconds(
                    minutes: ns.substring(with: match.range(at: 1)),
                    seconds: ns.substring(with: match.range(at: 2))))
            }
            guard !times.isEmpty else { continue }  // metadata tag like [ar:...]

            let body = ns.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            let (text, words) = extractWords(from: body)
            for time in times {
                collected.append((time, text, words))
            }
        }

        // Stable: two lines stamped with the same time keep the file's order.
        // Swift's sort makes no such promise, so they could swap between runs.
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
                voicedEnd: voiced))
        }
        return lines
    }

    /// Splits `body` into plain text plus word timings, if the file uses `<mm:ss.xx>` tags.
    private static func extractWords(from body: String) -> (String, [LyricWord]) {
        let ns = body as NSString
        let matches = wordTag.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (body, []) }

        var words: [LyricWord] = []
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

    /// Spreads a line's duration across its words, weighted by syllable count.
    ///
    /// Line-timed LRC — which is most of LRCLIB — only says when a line starts.
    /// Sweeping it at a constant rate puts the highlight mid-line exactly halfway
    /// through, which is almost never where the singer is. Weighting by syllables
    /// makes the highlight linger on "shine" and skip through "in the", which is
    /// much closer to how the line is actually sung.
    ///
    /// It is an estimate. Held notes and rests still drift, and the sync trim
    /// remains the fix for a line that runs consistently early or late.
    static func estimateWords(text: String, from start: Double,
                              to end: Double) -> (words: [LyricWord], voicedEnd: Double) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return ([], start) }
        let available = max(0.2, end - start)

        // Classified before anything is timed, because it changes the timing.
        // A backing vocal in brackets is sung *underneath* the lead, not before
        // it — "(Play with me) up all night, baby" is one moment, not two. Left
        // in the same queue as the lead it eats the front of the line and shoves
        // the words the singer needs a second or more late, which is exactly
        // what a heavily ad-libbed track looked like.
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

        // Asides are counted like any other word, because they take real time
        // to sing. The song this was tested against proves it: its ad-lib
        // appears alone on its own lines, where it occupies 0.245-0.402s per
        // syllable. Treating it as free — on the theory that a backing vocal is
        // layered under the lead — implied the singer drawling "bright lights"
        // across a whole second, and started the lead up to 1.6s before it is
        // actually sung. That is what "slightly ahead" was.
        //
        // `end` is the *next* line's start, so it includes whatever silence
        // follows. Spreading over all of it makes the highlight crawl behind
        // the singer through every gap, so the span is capped at a plausible
        // sung pace and the line finishes early instead of lagging.
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

    /// The slowest pace still treated as singing rather than silence.
    ///
    /// This only caps the sweep when a line's interval is longer than the words
    /// could plausibly fill — a genuine instrumental gap. For everything else
    /// the interval to the next line *is* the measurement of how fast it was
    /// sung, and the sweep should use all of it.
    ///
    /// It was 0.33s, which is close to the median pace, so it clipped a quarter
    /// of all lines: measured over 8,192 back-to-back lines in the local lyric
    /// cache, 27% were sung slower than that and had their sweep cut short by
    /// 0.85s on average — the highlight finishing early and sitting ahead of the
    /// singer, worst on slow or sustained verses. At 0.50s that falls to 8%.
    ///
    /// The cost lands on lines that really are followed by a gap, whose sweep
    /// now runs longer. There are 190 of those against 8,192, so the trade is
    /// heavily one way.
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
        // Trailing silent "e": "shine" is one beat, not two.
        if count > 1, word.count > 2, word.lowercased().hasSuffix("e") { count -= 1 }
        return max(1, count)
    }

    private static func seconds(minutes: String, seconds secondsField: String) -> Double {
        // Some files use [01:23:45] with a colon before the fraction.
        let normalized = secondsField.replacingOccurrences(of: ":", with: ".")
        return (Double(minutes) ?? 0) * 60 + (Double(normalized) ?? 0)
    }
}
