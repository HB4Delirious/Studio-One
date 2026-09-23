import Foundation

/// Which pitch-correction plug-in the key is being sent to.
///
/// They do not agree on how a key is expressed, and there are three different
/// answers among the four supported here:
///
/// - **Root plus scale menus** — Logic's Pitch Correction, Auto-Tune, Waves Tune
///   Real-Time. The scale menus are the problem: Auto-Tune's has at least
///   Major, Minor and Chromatic, and Waves' has, in its manual's words, "many,
///   many" — in an order no manual gives. A controller value that means Minor to
///   one of them means something else to the next.
/// - **Twelve note switches** — MetaTune. It has no key or scale parameter at
///   all. Its key menu just turns its twelve notes on and off, and those twelve
///   are what a host can automate; Slate's own instructions for automating
///   MetaTune's key are to record those note lanes.
/// - **Root plus a two-way major/minor switch** — what the bridge sent before
///   there was a choice, built for Topline Vocal Suite. Kept as it was.
///
/// The root-and-menu plug-ins are handled without ever touching the scale menu:
/// the plug-in is left on Major and a minor key is sent as its relative major.
/// D minor and F major are the same seven notes, and a correction grid is only
/// the set of notes it allows, so the tuning is identical. The one visible
/// difference is that the plug-in reads "F Major" while D minor is playing.
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

    /// One per mic. Each listens on its own MIDI channel — 1 for the first, 2
    /// for the second — so every plug-in has an assignment of its own. Driving
    /// two plug-ins from one assignment is something Logic supports but did not
    /// hold in practice on the karaoke rig; separate channels don't depend on it.
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

    /// Nothing changes for anyone until they choose: the layout they may
    /// already have assigned in Logic stays the default.
    static var current: PitchPlugin {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(PitchPlugin.init) ?? .original
    }

    static var invertsNotes: Bool {
        UserDefaults.standard.bool(forKey: invertNotesKey)
    }

    /// The ones on offer, in the rig's order of preference: MetaTune first,
    /// Topline second, Logic's own Pitch Correction as the fallback that is
    /// always there.
    ///
    /// Auto-Tune Access and Waves Tune Real-Time still work but are no longer
    /// offered. Whichever is already chosen stays listed, so an existing setup
    /// never changes under anyone; choose another and it drops out of the list.
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

    /// The pitch classes in a key, as a set of 0–11.
    static func notes(root: Int, minor: Bool) -> Set<Int> {
        Set((minor ? minorSteps : majorSteps).map { (root + $0) % 12 })
    }

    /// Everything to send for one key, in order.
    ///
    /// With a reading, the root and scale go out exactly as the plug-in's own
    /// menus lay them out, and a minor key is sent as minor. Without one, the
    /// scale menu's layout is unknown and the relative-major fallback below is
    /// the only thing guaranteed to give the right notes.
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
    /// menu, whatever rounding the receiving end uses.
    ///
    /// A host scales 0–127 onto a menu, and hosts and plug-ins do not agree on
    /// how. Four rules are in use: round to nearest, truncate, and two ways of
    /// dividing the range into equal bins. The bridge used to send
    /// `index * 127 / 11`, which is right under rounding and wrong under
    /// truncation for five of the twelve keys — D, E, F♯, G♯ and A♯ each landed
    /// one note flat. This picks the middle of the values all four rules agree
    /// on, which exists for every position of any menu up to thirteen long.
    /// The ends are sent as 0 and 127 exactly, which every rule reads the same.
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
