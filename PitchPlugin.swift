import Foundation

/// Which pitch-correction plug-in the key is being sent to.
///
/// Plug-ins express a key in one of three ways:
///
/// - **Root plus scale menus** — Logic's Pitch Correction, Auto-Tune, Waves
///   Tune Real-Time — whose scale menus are laid out differently and mostly
///   undocumented, so one value means Minor to one and something else to the
///   next. Unless the plug-in has been read (`PluginReader`), the scale menu is
///   left on Major and a minor key goes out as its relative major: D minor and
///   F major are the same seven notes, so the tuning is identical.
/// - **Twelve note switches** — MetaTune, whose key menu only switches notes
///   on and off. Those switches are all a host can automate.
/// - **Root plus a major/minor switch** — Topline Vocal Suite.
enum PitchPlugin: String, CaseIterable, Identifiable {
    case original
    case logicPitchCorrection
    case autoTuneAccess
    case wavesTuneRealTime
    case metaTune

    var id: String { rawValue }

    static let defaultsKey = "pitchPlugin"
    static let invertNotesKey = "pitchPluginInvertNotes"
    static let tunerCountKey = "pitchTunerCount"

    /// One per mic, each on its own MIDI channel (Mic 1 on 1, …), so every
    /// plug-in has an assignment of its own rather than sharing one.
    static var tunerCount: Int {
        min(4, max(1, UserDefaults.standard.integer(forKey: tunerCountKey)))
    }

    /// What was read from the installed plug-in, if it has been. See
    /// `PluginReader`.
    var reading: PluginReading? { PluginReading.stored(for: self) }

    /// Whether the plug-in can be read from this Mac at all. Logic's own
    /// Pitch Correction exists only inside Logic, and MetaTune's key is twelve
    /// switches rather than a menu.
    var isReadable: Bool { PluginReader.target(for: self) != nil }

    /// Topline's layout until another is chosen.
    static var current: PitchPlugin {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(PitchPlugin.init) ?? .original
    }

    static var invertsNotes: Bool {
        UserDefaults.standard.bool(forKey: invertNotesKey)
    }

    /// The ones on offer, in order of preference: MetaTune, Topline, then
    /// Logic's own Pitch Correction, which is always there. Auto-Tune and
    /// Waves still work, and stay listed while chosen.
    static let offered: [PitchPlugin] = [.metaTune, .original, .logicPitchCorrection]

    static func listed(keeping chosen: PitchPlugin) -> [PitchPlugin] {
        offered.contains(chosen) ? offered : offered + [chosen]
    }

    var displayName: String {
        switch self {
        case .original:             return "Topline Vocal Suite"
        case .logicPitchCorrection: return "Logic Pitch Correction"
        case .autoTuneAccess:       return "Antares Auto-Tune Access"
        case .wavesTuneRealTime:    return "Waves Tune Real-Time"
        case .metaTune:             return "Slate Digital MetaTune"
        }
    }

    enum Scheme {
        case rootAndMode
        case relativeMajorRoot
        case noteSwitches
    }

    var scheme: Scheme {
        switch self {
        case .original: return .rootAndMode
        case .logicPitchCorrection, .autoTuneAccess, .wavesTuneRealTime: return .relativeMajorRoot
        case .metaTune: return .noteSwitches
        }
    }

    // MARK: - Controllers

    /// See `MIDIBridge.mackieSafe` for the alternative numbers.
    static var rootCC: UInt8 { MIDIBridge.mackieSafe ? 85 : 20 }
    static var modeCC: UInt8 { MIDIBridge.mackieSafe ? 86 : 21 }

    /// C through B. 102–119 is a block the MIDI spec leaves undefined, so nothing
    /// else on the port will be using these.
    static let firstNoteCC: UInt8 = 102
    static func noteCC(_ pitchClass: Int) -> UInt8 { firstNoteCC + UInt8(pitchClass) }

    static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    private static let majorSteps = [0, 2, 4, 5, 7, 9, 11]
    private static let minorSteps = [0, 2, 3, 5, 7, 8, 10]

    /// A key's notes by name, from the root up, and the five it leaves out —
    /// for saying what MetaTune should show rather than which controllers moved.
    static func noteLists(root: Int, minor: Bool) -> (on: [String], off: [String]) {
        let inKey = notes(root: root, minor: minor)
        let fromRoot = (0..<12).map { (root + $0) % 12 }
        return (fromRoot.filter { inKey.contains($0) }.map { noteNames[$0] },
                (0..<12).filter { !inKey.contains($0) }.map { noteNames[$0] })
    }

    /// The pitch classes in a key, as a set of 0–11.
    static func notes(root: Int, minor: Bool) -> Set<Int> {
        Set((minor ? minorSteps : majorSteps).map { (root + $0) % 12 })
    }

    /// Everything to send for one key, in order. With a reading, the root and
    /// scale go out as the plug-in's own menus lay them out; without one, a
    /// minor key goes out as its relative major.
    func messages(root: Int, minor: Bool, invertNotes: Bool = false,
                  reading: PluginReading? = nil) -> [(cc: UInt8, value: UInt8)] {
        if scheme != .noteSwitches, let reading {
            if reading.canSendScale, let scale = minor ? reading.minorValue : reading.majorValue {
                return [(Self.rootCC, UInt8(reading.rootValues[root])), (Self.modeCC, UInt8(scale))]
            }
            let majorRoot = minor ? (root + 3) % 12 : root
            return [(Self.rootCC, UInt8(reading.rootValues[majorRoot]))]
        }
        switch scheme {
        case .rootAndMode:
            return [(Self.rootCC, Self.stepValue(root, of: 12)),
                    (Self.modeCC, minor ? 127 : 0)]

        case .relativeMajorRoot:
            // A minor key's relative major sits three semitones above it.
            let majorRoot = minor ? (root + 3) % 12 : root
            return [(Self.rootCC, Self.stepValue(majorRoot, of: 12))]

        case .noteSwitches:
            let inKey = Self.notes(root: root, minor: minor)
            return (0..<12).map { pitchClass in
                let on = inKey.contains(pitchClass) != invertNotes
                return (Self.noteCC(pitchClass), on ? 127 : 0)
            }
        }
    }

    /// What the plug-in should show once it has received `root`/`minor`, so a
    /// test send can be checked by eye.
    func expectedReading(root: Int, minor: Bool, reading: PluginReading? = nil) -> String {
        if scheme != .noteSwitches, let reading, reading.canSendScale,
           let scaleName = minor ? reading.minorName : reading.majorName {
            return "\(Self.noteNames[root]) \(scaleName)"
        }
        switch scheme {
        case .rootAndMode:
            return "\(Self.noteNames[root]) \(minor ? "minor" : "major")"
        case .relativeMajorRoot:
            let majorRoot = minor ? (root + 3) % 12 : root
            return "\(Self.noteNames[majorRoot]) Major" + (minor ? " — the relative major of \(Self.noteNames[root]) minor" : "")
        case .noteSwitches:
            let lit = Self.notes(root: root, minor: minor).sorted { ($0 - root + 12) % 12 < ($1 - root + 12) % 12 }
            return lit.map { Self.noteNames[$0] }.joined(separator: " ") + " switched on, the other five off"
        }
    }

    // MARK: - Encoding

    /// The controller value that selects position `index` of a `count`-position
    /// menu, whatever rounding the receiving end uses. Hosts map 0–127 onto a
    /// menu by one of four rules (round, truncate, two kinds of equal bins);
    /// this is the middle of the values all four agree on, which exists for
    /// any menu up to thirteen long. The ends are exactly 0 and 127.
    static func stepValue(_ index: Int, of count: Int) -> UInt8 {
        guard count > 1 else { return 0 }
        let position = min(max(index, 0), count - 1)
        if position == 0 { return 0 }
        if position == count - 1 { return 127 }

        let agreed = (0...127).filter { value in
            rules.allSatisfy { $0(value, count) == position }
        }
        if !agreed.isEmpty { return UInt8(agreed[agreed.count / 2]) }
        // Past thirteen positions the rules can no longer all be met; rounding
        // to nearest is the most common of them.
        return UInt8((Double(position) * 127 / Double(count - 1)).rounded())
    }

    private static let rules: [@Sendable (Int, Int) -> Int] = [
        { v, n in Int((Double(v) * Double(n - 1) / 127).rounded()) },
        { v, n in Int((Double(v) * Double(n - 1) / 127).rounded(.down)) },
        { v, n in min(n - 1, Int((Double(v) * Double(n) / 127).rounded(.down))) },
        { v, n in Int((Double(v) * Double(n) / 128).rounded(.down)) },
    ]
}
