import Foundation

struct SearchResult: Identifiable, Hashable {
    let id: String
    let uri: String
    let name: String
    let artist: String
    let album: String
    let duration: Double
    let artworkURL: URL?
}

enum SpotifyAPIError: LocalizedError {
    case missingCredentials
    case authFailed(Int)
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Add your Spotify client ID and secret in Settings to search."
        case .authFailed(let code):
            return "Spotify rejected those credentials (HTTP \(code)). Check the client ID and secret."
        case .requestFailed(let code):
            return "Spotify search failed (HTTP \(code))."
        }
    }
}

/// Spotify's Web API with the app's own client credentials: catalogue search,
/// which needs no sign-in. Anything of the user's own goes through
/// `SpotifyAccount`.
actor SpotifyAPI {

    static let shared = SpotifyAPI()

    private var accessToken: String?
    private var expiresAt: Date = .distantPast

    // MARK: - Search

    /// Documented as 50, but search answers 400 "Invalid limit" above 10.
    static let maxSearchLimit = 10

    func search(_ query: String, limit: Int = maxSearchLimit) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(min(limit, Self.maxSearchLimit)))
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12

        // A token that went stale in flight gets one fresh try.
        var data = Data()
        var status = 0
        for attempt in 0..<2 {
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            let (body, response) = try await URLSession.shared.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 401, attempt == 0 else { break }
            accessToken = nil
            expiresAt = .distantPast
        }
        guard status == 200 else { throw SpotifyAPIError.requestFailed(status) }

        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        return envelope.tracks.items.map { item in
            SearchResult(
                id: item.id,
                uri: item.uri,
                name: item.name,
                artist: item.artists.map(\.name).joined(separator: ", "),
                album: item.album.name,
                duration: Double(item.duration_ms) / 1000,
                artworkURL: item.album.images.last.flatMap { URL(string: $0.url) })
        }
    }

    // MARK: - Token

    /// Fetches the token early, ignoring failure: cold, the keychain read and
    /// OAuth round trip can take long enough to miss the first song's lookup.
    func warm() async { _ = try? await token() }

    private func token() async throws -> String {
        if let accessToken, Date() < expiresAt.addingTimeInterval(-30) {
            return accessToken
        }

        guard let id = Credentials.read(.clientID), !id.isEmpty,
              let secret = Credentials.read(.clientSecret), !secret.isEmpty else {
            throw SpotifyAPIError.missingCredentials
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SpotifyAPIError.authFailed(status) }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = payload.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(payload.expires_in))
        return payload.access_token
    }

    /// Call after the user edits credentials so the next request re-authenticates.
    func resetToken() {
        accessToken = nil
        expiresAt = .distantPast
    }

    // MARK: - Wire format

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private struct SearchEnvelope: Decodable {
        let tracks: Tracks

        struct Tracks: Decodable {
            let items: [Item]
        }

        struct Item: Decodable {
            let id: String
            let uri: String
            let name: String
            let duration_ms: Int
            let artists: [Artist]
            let album: Album
        }

        struct Artist: Decodable {
            let name: String
        }

        struct Album: Decodable {
            let name: String
            let images: [Image]
        }

        struct Image: Decodable {
            let url: String
            let width: Int?
            let height: Int?
        }
    }
}
