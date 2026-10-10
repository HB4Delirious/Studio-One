import Foundation

/// One setting remembered per song: a dictionary of track ID → value under a
/// single defaults key. Setting the `neutral` value, or nil, forgets the song
/// rather than storing a value that changes nothing.
struct PerSongSetting<Value: Equatable> {
    let key: String
    let neutral: Value?

    init(_ key: String, neutral: Value? = nil) {
        self.key = key
        self.neutral = neutral
    }

    subscript(trackID: String) -> Value? {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: Value])?[trackID] }
        nonmutating set {
            var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Value] ?? [:]
            all[trackID] = newValue == neutral ? nil : newValue
            UserDefaults.standard.set(all, forKey: key)
        }
    }
}
