import Foundation

/// NetEase Cloud Music as a second lyrics source, used only when LRCLIB has
/// nothing timed.
///
/// Its catalogue reaches well into Western music and often carries timing
/// word by word ("yrc"), not just line by line — checked against Duran Duran
/// and Toto. The endpoints are the ones its own web player and long-standing
/// lyric apps use; they are not a published API, so they could change without
/// notice. Everything here fails quietly to "nothing found" if they do, and
/// the source can be switched off in Settings › Display.
enum NetEaseLyrics {

    static let enabledKey = "lyricsNetEase"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    struct Found {
        let lrc: String
        let wordTimed: Bool
    }

    /// Timed lyrics for a song, as LRC (enhanced with word tags when NetEase
    /// has word timing), or nil.
    static func lyrics(title: String, artist: String, duration: Double) async -> Found? {
        guard let id = await match(title: title, artist: artist, duration: duration),
              let url = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1&yv=1"),
              let object = await json(url) else { return nil }

        if let yrc = (object["yrc"] as? [String: Any])?["lyric"] as? String,
           let lrc = convertWordTimed(yrc), !LRCParser.parse(lrc).isEmpty {
            return Found(lrc: lrc, wordTimed: true)
        }
        if let plain = (object["lrc"] as? [String: Any])?["lyric"] as? String {
            let lrc = cleanLineTimed(plain)
            if LRCParser.parse(lrc).contains(where: { !$0.isBlank }) { return Found(lrc: lrc, wordTimed: false) }
        }
        return nil
    }

    // MARK: - Finding the song

    /// The best search hit: title and artist must agree, and of those the
    /// closest in length — a live take or an extended mix would drift.
    private static func match(title: String, artist: String, duration: Double) async -> Int? {
        var components = URLComponents(string: "https://music.163.com/api/search/get")!
        components.queryItems = [
            URLQueryItem(name: "s", value: "\(title) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url, let object = await json(url),
              let songs = (object["result"] as? [String: Any])?["songs"] as? [[String: Any]] else { return nil }

        let candidates = songs.compactMap { song -> (id: Int, gap: Double)? in
            guard let id = song["id"] as? Int, let name = song["name"] as? String else { return nil }
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            guard titlesAgree(name, title), artistsOverlap(artists.joined(separator: " "), artist) else { return nil }
            let length = Double(song["duration"] as? Int ?? 0) / 1000
            let gap = length > 0 && duration > 0 ? abs(length - duration) : 0
            return gap <= 5 ? (id, gap) : nil
        }
        return candidates.min { $0.gap < $1.gap }?.id
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }

    private static func titlesAgree(_ a: String, _ b: String) -> Bool {
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return a.lowercased() == b.lowercased() }
        let (fewer, more) = left.count <= right.count ? (left, right) : (right, left)
        return Double(fewer.intersection(more).count) / Double(fewer.count) >= 0.6
    }

    private static func artistsOverlap(_ a: String, _ b: String) -> Bool {
        !words(a).isDisjoint(with: words(b))
    }

    /// Its own session, with no cookies. NetEase sets one on the first
    /// request, and once a client sends it back its search answers with
    /// unrelated filler — Chinese pop hits for "Africa TOTO". Found when a
    /// second lookup in the same run failed; a cookie-free session got the
    /// right song every time. The shared session keeps cookies.
    /// (Ephemeral alone isn't enough: it still keeps cookies in memory for
    /// its own lifetime, so the second song in a session failed.)
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private static func json(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) Studio One", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Formats

    /// Credit lines NetEase puts first: lyricist, composer, arranger, producer.
    private static let creditPrefixes = ["作词", "作曲", "编曲", "制作人", "制作", "监制", "混音", "母带",
                                         "和声", "录音", "出品", "lyricist", "composer", "arranger",
                                         "producer", "lyrics by", "music by", "written by"]

    static func isCredit(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return creditPrefixes.contains { prefix in
            guard trimmed.hasPrefix(prefix) else { return false }
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix(":") || rest.hasPrefix("：")
        }
    }

    /// Full-width brackets, which NetEase uses around backing vocals, become
    /// the plain ones the lyric view knows to float as asides.
    static func plainBrackets(_ text: String) -> String {
        text.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
    }

    /// Line-timed LRC, less the credits.
    static func cleanLineTimed(_ lrc: String) -> String {
        lrc.components(separatedBy: .newlines).filter { line in
            guard let close = line.firstIndex(of: "]") else { return false }
            return !isCredit(String(line[line.index(after: close)...]))
        }
        .map(plainBrackets)
        .joined(separator: "\n")
    }

    private static let lineHead = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
    private static let wordTag = try! NSRegularExpression(pattern: #"\((\d+),(\d+),-?\d+\)"#)

    /// Word-timed "yrc" as enhanced LRC.
    ///
    /// A yrc line is `[start,duration]` then `(start,duration,0)text` per
    /// piece, in milliseconds. Pieces are not always words: "city" and ", "
    /// arrive separately, "12", ":" and "30 " too. They are joined until one
    /// ends in a space, and the word takes its first piece's time. Where a line
    /// ends well before the next begins, a blank line marks the gap, so the
    /// last word isn't held lit through a solo.
    static func convertWordTimed(_ yrc: String) -> String? {
        var output: [String] = []
        var lastEnd: Int?

        for raw in yrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let head = lineHead.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let start = Int(ns.substring(with: head.range(at: 1))),
                  let length = Int(ns.substring(with: head.range(at: 2))) else { continue }

            let body = ns.substring(from: head.range.location + head.range.length)
            let bodyNS = body as NSString
            let tags = wordTag.matches(in: body, range: NSRange(location: 0, length: bodyNS.length))
            var pieces: [(time: Int, text: String)] = []
            for (index, tag) in tags.enumerated() {
                let textStart = tag.range.location + tag.range.length
                let textEnd = index + 1 < tags.count ? tags[index + 1].range.location : bodyNS.length
                guard textEnd > textStart, let time = Int(bodyNS.substring(with: tag.range(at: 1))) else { continue }
                pieces.append((time, bodyNS.substring(with: NSRange(location: textStart, length: textEnd - textStart))))
            }
            let text = pieces.map(\.text).joined()
            guard !pieces.isEmpty, !isCredit(text) else { continue }

            if let lastEnd, start - lastEnd > 3000 {
                output.append(stamp(lastEnd, bracket: "[]"))
            }

            var words: [(time: Int, text: String)] = []
            var current: (time: Int, text: String)?
            for piece in pieces {
                if current == nil { current = piece } else { current!.text += piece.text }
                if piece.text.last?.isWhitespace == true {
                    words.append(current!)
                    current = nil
                }
            }
            if let current { words.append(current) }

            let tagged = words.map { stamp($0.time, bracket: "<>") + plainBrackets($0.text) }.joined()
            output.append(stamp(start, bracket: "[]") + tagged.trimmingCharacters(in: .whitespaces))
            lastEnd = start + length
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    private static func stamp(_ milliseconds: Int, bracket: String) -> String {
        let total = max(0, milliseconds)
        let minutes = total / 60_000
        let seconds = Double(total % 60_000) / 1000
        return "\(bracket.first!)" + String(format: "%02d:%05.2f", minutes, seconds) + "\(bracket.last!)"
    }
}
