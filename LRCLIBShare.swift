import CryptoKit
import Foundation

/// Sharing a tapped-out timing on LRCLIB, so everyone else's players get it.
///
/// LRCLIB takes contributions without accounts: the client asks for a
/// challenge, works a small proof of work — find a number that, appended to
/// the prefix, hashes (SHA-256) at or below the target — and sends the lyrics
/// with "prefix:number" as a one-time token. The same scheme as LRCGET, the
/// reference client LRCLIB's documentation points to. Public, so it only
/// ever happens when asked for.
enum LRCLIBShare {

    private static let base = URL(string: "https://lrclib.net")!
    private static let userAgent = "Studio One (macOS karaoke; tap-timed lyrics)"

    enum ShareError: LocalizedError {
        case challenge(Int)
        case rejected(Int, String)
        case nothingToShare

        var errorDescription: String? {
            switch self {
            case .challenge(let status): return "LRCLIB didn't hand out a challenge (HTTP \(status))."
            case .rejected(let status, let message):
                return "LRCLIB turned it down (HTTP \(status))\(message.isEmpty ? "" : ": \(message)")."
            case .nothingToShare: return "There's no timing of yours to share for this song."
            }
        }
    }

    struct Challenge { let prefix: String; let target: String }

    static func requestChallenge() async throws -> Challenge {
        var request = URLRequest(url: base.appendingPathComponent("api/request-challenge"))
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefix = object["prefix"] as? String, let target = object["target"] as? String else {
            throw ShareError.challenge(status)
        }
        return Challenge(prefix: prefix, target: target)
    }

    /// The smallest nonce whose hash is at or below the target, compared byte
    /// by byte from the front — as LRCGET does. Stops early if cancelled.
    static func solve(_ challenge: Challenge) -> String? {
        guard let target = bytes(fromHex: challenge.target) else { return nil }
        var nonce = 0
        while true {
            if nonce % 50_000 == 0, Task.isCancelled { return nil }
            let digest = Array(SHA256.hash(data: Data((challenge.prefix + String(nonce)).utf8)))
            if meets(digest, target) { return String(nonce) }
            nonce += 1
        }
    }

    static func meets(_ digest: [UInt8], _ target: [UInt8]) -> Bool {
        guard digest.count == target.count else { return false }
        for (a, b) in zip(digest, target) {
            if a > b { return false }
            if a < b { return true }
        }
        return true
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { return nil }
        return stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...$0 + 1]), radix: 16)
        }.reduce(into: [UInt8]?([])) { result, byte in
            guard let byte, result != nil else { result = nil; return }
            result!.append(byte)
        }
    }

    /// What is sent: the song as the player names it, its length, and the
    /// lyrics both timed and plain. Our own "[by:]" line is left out.
    static func body(trackName: String, artistName: String, albumName: String,
                     duration: Double, synced: String) -> [String: Any] {
        let lines = synced.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("[by:") && !$0.hasPrefix("[ar:") && !$0.hasPrefix("[ti:") }
        let plain = lines.map { line -> String in
            guard let close = line.lastIndex(of: "]") else { return line }
            return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return [
            "trackName": trackName,
            "artistName": artistName,
            "albumName": albumName,
            "duration": duration,
            "plainLyrics": plain.joined(separator: "\n"),
            "syncedLyrics": lines.joined(separator: "\n"),
        ]
    }

    /// Publishes timed lyrics for one song. `synced` is LRC; the plain
    /// version is derived from it.
    static func publish(trackName: String, artistName: String, albumName: String,
                        duration: Double, synced: String) async throws {
        let body = self.body(trackName: trackName, artistName: artistName, albumName: albumName,
                             duration: duration, synced: synced)
        let challenge = try await requestChallenge()
        let nonce = await Task.detached(priority: .userInitiated) { solve(challenge) }.value
        guard let nonce else { throw CancellationError() }

        var request = URLRequest(url: base.appendingPathComponent("api/publish"))
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(challenge.prefix):\(nonce)", forHTTPHeaderField: "X-Publish-Token")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 || status == 200 else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            throw ShareError.rejected(status, message ?? "")
        }
    }
}
