import Foundation
import Security

/// Client ID and secret live in the login keychain, not in source and not in UserDefaults.
enum Credentials {

    private static let service = "SpotifyKaraoke.SpotifyAPI"

    enum Key: String {
        case clientID
        case clientSecret
        case songBPM
        /// Only present after Sign in to Spotify. See `SpotifyAccount`.
        case spotifyRefreshToken
    }

    static var isConfigured: Bool {
        !(read(.clientID) ?? "").isEmpty && !(read(.clientSecret) ?? "").isEmpty
    }

    static func read(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Updates in place, and adds only when there is nothing to update.
    ///
    /// This used to delete and then add. If the add failed — a locked
    /// keychain, say — the old value was already gone, and the Spotify refresh
    /// token is rewritten on every hourly renewal: one bad moment and you were
    /// signed out. Updating also keeps the item's access settings.
    @discardableResult
    static func write(_ value: String, for key: Key) -> Bool {
        guard !value.isEmpty else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(baseQuery(key) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            Diagnostics.log("keychain: couldn't update \(key.rawValue) (\(updated))")
            return false
        }
        var attributes = baseQuery(key)
        attributes[kSecValueData as String] = data
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added != errSecSuccess { Diagnostics.log("keychain: couldn't save \(key.rawValue) (\(added))") }
        return added == errSecSuccess
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
