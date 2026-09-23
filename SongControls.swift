import Foundation

/// Per-song settings for Logic: up to eight controls, each a plug-in
/// parameter you name and learn once — MetaTune's retune speed on Mic 1, a
/// reverb send, anything Logic can learn — whose value each song remembers.
/// When a song starts, its values go out alongside the key, so a ballad can
/// get gentle correction and a rap song a hard tune without anyone touching
/// the plug-in.
///
/// Absolute values, unlike the mixer dials' steps: a song's setting is a
/// place, not a nudge. They travel on channel 16, CC 70–77 — clear of the
/// mixer (30–61 with four mics), the key and tempo, and MetaTune's switches.
enum SongControl {

    static let count = 8
    static let firstCC: UInt8 = 70
    static let channel: UInt8 = 15              // MIDI channel 16

    static func cc(_ slot: Int) -> UInt8 { firstCC + UInt8(slot) }

    private static let namesKey = "songControlNames"
    private static let defaultsKey = "songControlDefaults"
    private static let valuesKey = "trackSongControls"

    /// A slot with no name is off: nothing is sent for it and it isn't shown.
    static var names: [String] {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: namesKey) ?? []
            return (0..<count).map { $0 < stored.count ? stored[$0] : "" }
        }
        set { UserDefaults.standard.set(Array(newValue.prefix(count)), forKey: namesKey) }
    }

    static var active: [Int] {
        names.indices.filter { !names[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Sent for songs with no value of their own; nil sends nothing.
    static func defaultValue(_ slot: Int) -> Int? {
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Int] ?? []
        guard slot < stored.count, stored[slot] >= 0 else { return nil }
        return min(127, stored[slot])
    }

    static func setDefault(_ value: Int?, slot: Int) {
        var stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Int] ?? []
        while stored.count < count { stored.append(-1) }
        stored[slot] = value.map { min(127, max(0, $0)) } ?? -1
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    /// This song's own value, if it has one.
    static func value(_ slot: Int, trackID: String) -> Int? {
        let all = UserDefaults.standard.dictionary(forKey: valuesKey) as? [String: [String: Int]] ?? [:]
        return all[trackID]?[String(slot)]
    }

    static func setValue(_ value: Int?, slot: Int, trackID: String) {
        var all = UserDefaults.standard.dictionary(forKey: valuesKey) as? [String: [String: Int]] ?? [:]
        var song = all[trackID] ?? [:]
        song[String(slot)] = value.map { min(127, max(0, $0)) }
        all[trackID] = song.isEmpty ? nil : song
        UserDefaults.standard.set(all, forKey: valuesKey)
    }

    /// What goes out for a song: its own value, else the default.
    static func effective(_ slot: Int, trackID: String) -> Int? {
        value(slot, trackID: trackID) ?? defaultValue(slot)
    }

    static func messages(trackID: String) -> [(cc: UInt8, value: UInt8)] {
        active.compactMap { slot in
            effective(slot, trackID: trackID).map { (cc(slot), UInt8($0)) }
        }
    }
}

extension KaraokeModel {
    /// This song's value for a slot, or the default, for the popover.
    func songControl(_ slot: Int) -> (value: Int?, isOwn: Bool) {
        guard let id = track?.trackID else { return (SongControl.defaultValue(slot), false) }
        let own = SongControl.value(slot, trackID: id)
        return (own ?? SongControl.defaultValue(slot), own != nil)
    }

    /// Saves for this song and sends straight away. No sweep: a slider being
    /// dragged passes through the values on its own.
    func setSongControl(_ slot: Int, to value: Int?) {
        guard let id = track?.trackID else { return }
        objectWillChange.send()
        SongControl.setValue(value, slot: slot, trackID: id)
        guard let sent = SongControl.effective(slot, trackID: id) else { return }
        MIDIBridge.shared.sendSongControls([(SongControl.cc(slot), UInt8(sent))], sweep: false,
                                           label: SongControl.names[slot])
    }
}
