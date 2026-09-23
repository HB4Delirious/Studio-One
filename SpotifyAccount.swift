import AppKit
import CryptoKit
import Foundation
import Network

/// Signing in to Spotify, for the one thing the desktop app's scripting cannot
/// give: your library.
///
/// Spotify's AppleScript dictionary has the current track and the transport and
/// nothing else — no playlists, no saved songs, no queue. The Web API has all
/// three, but only on behalf of a signed-in user. Search does not need this and
/// never did; it still runs on the client-credentials token in `SpotifyAPI`.
///
/// The flow is Authorization Code with PKCE, which is what Spotify asks desktop
/// apps to use:
///
/// - The login happens on Spotify's own page in your browser. Studio One never
///   sees your password.
/// - PKCE needs no client secret, only the client ID already in the keychain.
/// - What comes back is a refresh token, kept in the login keychain beside the
///   client ID. It can be revoked from Spotify's account page at any time, and
///   Sign out deletes it.
///
/// The redirect has to go to a fixed address registered in the Spotify
/// developer dashboard. Spotify stopped accepting `localhost` in November 2025
/// but still accepts the loopback IP, so a one-shot listener on 127.0.0.1 takes
/// the redirect. Port 8725 sits just above the request line's 8710–8719.
///
/// **What Spotify allows (rules applied to all development-mode apps from
/// March 2026):** your playlists and saved songs can be listed, but a playlist's
/// tracks are only returned for playlists you own or collaborate on — anything
/// you merely follow answers 403. Those are still listed, and say why they
/// will not open.
actor SpotifyAccount {

    static let shared = SpotifyAccount()

    static let callbackPort: UInt16 = 8725
    static let redirectURI = "http://127.0.0.1:8725/callback"

    /// Read your playlists, including private and collaborative ones; read your
    /// saved songs; read the queue.
    static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
        "user-read-playback-state",
    ]

    /// Not a secret: only whether and as whom. The token itself is in the
    /// keychain. Kept here so `canBrowseLibrary` can answer synchronously
    /// without a keychain read on every redraw.
    static let signedInNameKey = "spotifySignedInName"

    nonisolated static var isSignedIn: Bool {
        UserDefaults.standard.string(forKey: signedInNameKey) != nil
    }

    private var accessToken: String?
    private var expiresAt: Date = .distantPast
    private var userID: String?

    /// Playlist position → what is needed to open it again. `LibraryPlaylist`
    /// is addressed by an integer because Music's playlists have no stable ID;
    /// Spotify's do, so they are kept here against that integer.
    private var playlistRefs: [Int: PlaylistRef] = [:]

    struct PlaylistRef {
        let id: String?          // nil for Liked Songs
        let uri: String          // the playback context
        let imageURL: URL?
        let readable: Bool
    }

    // MARK: - Sign in

    /// Opens Spotify's login page and waits for it to come back. Returns the
    /// account's display name.
    func signIn() async throws -> String {
        guard let clientID = Credentials.read(.clientID), !clientID.isEmpty else {
            throw SpotifyAccountError.noClientID
        }

        let verifier = Self.randomURLSafe(bytes: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(bytes: 16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]

        // Listen before opening the page, or a fast redirect could arrive to
        // nothing.
        let callback = try LoopbackCallback(port: Self.callbackPort)
        let page = components.url!
        await MainActor.run { _ = NSWorkspace.shared.open(page) }
        let query = try await callback.wait(timeout: 180)

        if let error = query["error"] {
            throw error == "access_denied" ? SpotifyAccountError.denied : SpotifyAccountError.spotify(error)
        }
        guard query["state"] == state else { throw SpotifyAccountError.stateMismatch }
        guard let code = query["code"] else { throw SpotifyAccountError.spotify("no code returned") }

        try await exchange([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])

        let me = try await getJSON("https://api.spotify.com/v1/me")
        userID = me["id"] as? String
        let name = (me["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? userID ?? "Spotify"
        UserDefaults.standard.set(name, forKey: Self.signedInNameKey)
        Diagnostics.log("spotify: signed in")
        return name
    }

    func signOut() {
        Credentials.write("", for: .spotifyRefreshToken)
        UserDefaults.standard.removeObject(forKey: Self.signedInNameKey)
        accessToken = nil
        expiresAt = .distantPast
        userID = nil
        playlistRefs = [:]
        Diagnostics.log("spotify: signed out")
    }

    // MARK: - Library

    struct Track {
        let uri: String
        let name: String
        let artist: String
        let duration: Double
    }

    /// Liked Songs first, then every playlist in your Spotify sidebar.
    func playlists() async throws -> [(index: Int, name: String)] {
        let me = try await currentUserID()
        var result: [(Int, String)] = []
        var refs: [Int: PlaylistRef] = [:]

        refs[1] = PlaylistRef(id: nil, uri: "spotify:user:\(me):collection", imageURL: nil, readable: true)
        result.append((1, "Liked Songs"))

        let entries = try await paged("https://api.spotify.com/v1/me/playlists?limit=50", maxPages: 10)
        for entry in entries {
            guard let id = entry["id"] as? String, let uri = entry["uri"] as? String else { continue }
            let owner = (entry["owner"] as? [String: Any])?["id"] as? String
            let collaborative = entry["collaborative"] as? Bool ?? false
            let image = (entry["images"] as? [[String: Any]])?.first?["url"] as? String
            let index = result.count + 1
            refs[index] = PlaylistRef(id: id, uri: uri, imageURL: image.flatMap(URL.init(string:)),
                                      readable: owner == me || collaborative)
            // Spotify allows a playlist with an empty name; it showed as a blank row.
            let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            result.append((index, name.isEmpty ? "Untitled" : name))
        }
        playlistRefs = refs
        return result
    }

    /// The tracks of one playlist, and the context to play them in so the next
    /// song follows on from the playlist rather than stopping.
    func tracks(inPlaylist index: Int) async throws -> (tracks: [Track], context: String) {
        guard let ref = playlistRefs[index] else { throw SpotifyAccountError.spotify("playlist list is stale") }
        guard ref.readable else { throw SpotifyAccountError.notOwned }

        let entries: [[String: Any]]
        if let id = ref.id {
            // `item` replaced `track` in the 2026 API; older responses carry
            // only `track`. Local files and podcast episodes cannot be started
            // by URI from a script, so they are left out.
            entries = try await paged("https://api.spotify.com/v1/playlists/\(id)/items?limit=50",
                                      maxPages: 20)
                .compactMap { ($0["item"] ?? $0["track"]) as? [String: Any] }
        } else {
            // Liked Songs, newest first. Capped at 500: a large collection
            // would otherwise be dozens of round trips before anything shows.
            entries = try await paged("https://api.spotify.com/v1/me/tracks?limit=50", maxPages: 10)
                .compactMap { $0["track"] as? [String: Any] }
        }
        return (entries.compactMap(Self.track(from:)), ref.uri)
    }

    func coverURL(forPlaylist index: Int) -> URL? { playlistRefs[index]?.imageURL }

    /// What is playing, then what is queued after it.
    func queue(limit: Int) async throws -> [Track]? {
        let body = try await getJSON("https://api.spotify.com/v1/me/player/queue", allowEmpty: true)
        guard let current = (body["currently_playing"] as? [String: Any]).flatMap(Self.track(from:)) else {
            return nil
        }
        let queued = (body["queue"] as? [[String: Any]] ?? []).compactMap(Self.track(from:))
        return [current] + queued.prefix(limit)
    }

    private static func track(from object: [String: Any]) -> Track? {
        guard (object["type"] as? String ?? "track") == "track",
              object["is_local"] as? Bool != true,
              let uri = object["uri"] as? String, SpotifyController.isValidTrackURI(uri),
              let name = object["name"] as? String else { return nil }
        let artists = (object["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return Track(uri: uri, name: name, artist: artists.joined(separator: ", "),
                     duration: Double(object["duration_ms"] as? Int ?? 0) / 1000)
    }

    // MARK: - Requests

    private func currentUserID() async throws -> String {
        if let userID { return userID }
        let me = try await getJSON("https://api.spotify.com/v1/me")
        guard let id = me["id"] as? String else { throw SpotifyAccountError.spotify("no user id") }
        userID = id
        return id
    }

    /// Follows `next` links. `maxPages` bounds the wait on very large lists.
    private func paged(_ first: String, maxPages: Int) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var next: String? = first
        var pages = 0
        while let url = next, pages < maxPages {
            let page = try await getJSON(url)
            items += page["items"] as? [[String: Any]] ?? []
            next = page["next"] as? String
            pages += 1
        }
        return items
    }

    private func getJSON(_ url: String, allowEmpty: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(try await userToken())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case 204 where allowEmpty:
            return [:]
        case 401:
            accessToken = nil
            expiresAt = .distantPast
            throw SpotifyAccountError.http(status)
        case 403:
            throw SpotifyAccountError.notOwned
        default:
            throw SpotifyAccountError.http(status)
        }
    }

    // MARK: - Tokens

    /// The refresh in flight, shared by everyone who needs a token meanwhile.
    ///
    /// An actor still interleaves at every `await`. When the hourly token ran
    /// out, the library's burst of requests — playlists, a cover per card —
    /// each saw it expired and each refreshed with the same refresh token.
    /// Spotify may rotate that token on use; then the first refresh wins, the
    /// rest come back 400, and a 400 here means "revoked": signed out an hour
    /// into the evening. One refresh, awaited by all, can't race itself.
    private var refreshing: Task<Void, Error>?

    private func userToken() async throws -> String {
        if let accessToken, Date() < expiresAt.addingTimeInterval(-60) { return accessToken }
        let task: Task<Void, Error>
        if let refreshing {
            task = refreshing
        } else {
            task = Task { try await self.refreshAccessToken() }
            refreshing = task
        }
        defer { if refreshing == task { refreshing = nil } }
        try await task.value
        guard let accessToken else { throw SpotifyAccountError.signedOut }
        return accessToken
    }

    private func refreshAccessToken() async throws {
        guard let refresh = Credentials.read(.spotifyRefreshToken), !refresh.isEmpty,
              let clientID = Credentials.read(.clientID), !clientID.isEmpty else {
            throw SpotifyAccountError.signedOut
        }
        do {
            try await exchange(["grant_type": "refresh_token",
                                "refresh_token": refresh,
                                "client_id": clientID])
        } catch SpotifyAccountError.http(400) {
            // Revoked from Spotify's side, or expired. Signing in again is the
            // only way back, so say so rather than failing every call.
            signOut()
            throw SpotifyAccountError.signedOut
        }
    }

    /// Both the first sign-in and every refresh land here. Spotify may rotate
    /// the refresh token on refresh; when it does, the old one stops working, so
    /// the new one is stored straight away.
    private func exchange(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = body["access_token"] as? String else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            Diagnostics.log("spotify: token exchange HTTP \(status) \(reason ?? "")")
            throw SpotifyAccountError.http(status)
        }
        accessToken = token
        expiresAt = Date().addingTimeInterval(TimeInterval(body["expires_in"] as? Int ?? 3600))
        if let rotated = body["refresh_token"] as? String, !rotated.isEmpty {
            Credentials.write(rotated, for: .spotifyRefreshToken)
        }
    }

    // MARK: - Encoding

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }
}

enum SpotifyAccountError: LocalizedError, Equatable {
    case noClientID
    case denied
    case stateMismatch
    case timedOut
    case portBusy
    case notOwned
    case signedOut
    case http(Int)
    case spotify(String)

    var errorDescription: String? {
        switch self {
        case .noClientID:
            return "Add your Spotify client ID first."
        case .denied:
            return "Sign-in was cancelled on Spotify's page."
        case .stateMismatch:
            return "The sign-in reply didn't match the request. Try again."
        case .timedOut:
            return "Spotify never came back. If the browser showed \u{201C}Invalid redirect URI\u{201D}, add \(SpotifyAccount.redirectURI) to your app in the Spotify developer dashboard."
        case .portBusy:
            return "Port \(SpotifyAccount.callbackPort) is in use by something else, so Spotify's reply has nowhere to land."
        case .notOwned:
            return "Spotify only lets apps open playlists you own or collaborate on. This one plays fine in Spotify itself."
        case .signedOut:
            return "Sign in to Spotify to see your library."
        case .http(let code):
            return "Spotify answered HTTP \(code)."
        case .spotify(let message):
            return "Spotify: \(message)"
        }
    }
}

/// Takes exactly one browser redirect on 127.0.0.1 and hands back its query.
///
/// Bound to the loopback address only, so nothing else on the network can reach
/// it, and torn down as soon as the redirect arrives or the wait gives up.
/// Requests for anything other than /callback — a browser asks for
/// /favicon.ico unprompted — get a 404 and the wait continues.
final class LoopbackCallback: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.logan.SpotifyKaraoke.spotify-callback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw SpotifyAccountError.portBusy
        }
    }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                self.listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                self.listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.finish(.failure(SpotifyAccountError.portBusy)) }
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(SpotifyAccountError.timedOut))
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1" + target)

            guard components?.path == "/callback" else {
                self.reply(connection, status: "404 Not Found", body: "")
                return
            }
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }

            let ok = query["code"] != nil
            self.reply(connection, status: "200 OK", body: Self.page(ok: ok))
            self.finish(.success(query))
        }
    }

    private func reply(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }

    private static func page(ok: Bool) -> String {
        let message = ok ? "Signed in. You can close this tab and go back to Studio One."
                         : "Sign-in didn't finish. Go back to Studio One and try again."
        return """
        <!doctype html><meta charset="utf-8"><title>Studio One</title>
        <body style="font:16px -apple-system,system-ui;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0">
        <p>\(message)</p></body>
        """
    }
}

/// Sign-in state for the views. The browser reloads the library when this
/// changes, and Settings and the empty Spotify library both drive it.
@MainActor
final class SpotifySession: ObservableObject {

    static let shared = SpotifySession()

    @Published private(set) var name: String? = UserDefaults.standard.string(forKey: SpotifyAccount.signedInNameKey)
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                name = try await SpotifyAccount.shared.signIn()
            } catch {
                self.error = error.localizedDescription
                Diagnostics.log("spotify: sign-in failed — \(error.localizedDescription)")
            }
            busy = false
        }
    }

    func signOut() {
        Task {
            await SpotifyAccount.shared.signOut()
            name = nil
        }
    }
}
