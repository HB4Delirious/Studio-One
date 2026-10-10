import Foundation

/// The mic-channel controls the Stream Deck's dials drive in Logic.
///
/// Logic has no scripting worth the name, but it learns MIDI, and it can aim an
/// assignment at a numbered channel strip rather than "whatever is selected" —
/// so a dial can own Mic RED whatever you happen to be clicking on.
///
/// **Dials send steps, not positions.** A position would be a value this app
/// invents, and Pickup mode ignores it until it reaches the parameter's own; a
/// step moves the fader from wherever it is, and can't jump. The cost: the
/// dials show what they sent, not where Logic's faders are.
struct MixerControl: Identifiable, Hashable {

    enum Kind: String { case dial, button }

    let id: String          // "mic1.level"
    let name: String        // "Mic 1 · Level"
    let cc: UInt8
    let kind: Kind
    let mic: Int

    static let firstCC: UInt8 = 30
    /// Level, Send A, Send B, four plug-in parameters, Mute.
    static let perMic = 8

    /// Channel 16, apart from the tuners' 1–4, so the two can't collide
    /// however many mics or controls are added. CC 30 up, eight per mic.
    static let channel: UInt8 = 15

    /// One set per mic, following "Mics with a tuner" in Settings.
    static var all: [MixerControl] {
        controls(mics: PitchPlugin.tunerCount)
    }

    static func controls(mics: Int) -> [MixerControl] {
        // The plug-in slots are deliberately unnamed: whatever you learn them
        // to. One might be Waves Tune's correction amount, the next a gate
        // threshold — Logic doesn't care and neither does this.
        let parts: [(String, String, Kind)] = [
            ("level", "Level", .dial),
            ("sendA", "Send A", .dial),
            ("sendB", "Send B", .dial),
            ("plugin1", "Plug-in 1", .dial),
            ("plugin2", "Plug-in 2", .dial),
            ("plugin3", "Plug-in 3", .dial),
            ("plugin4", "Plug-in 4", .dial),
            ("mute", "Mute", .button),
        ]
        return (1...max(1, mics)).flatMap { mic in
            parts.enumerated().map { offset, part in
                MixerControl(id: "mic\(mic).\(part.0)",
                             name: "Mic \(mic) · \(part.1)",
                             cc: firstCC + UInt8((mic - 1) * perMic + offset),
                             kind: part.2,
                             mic: mic)
            }
        }
    }

    static func named(_ id: String) -> MixerControl? {
        all.first { $0.id == id }
    }

    /// The mute of the same mic, for a dial's press.
    var mute: MixerControl? {
        Self.all.first { $0.mic == mic && $0.kind == .button }
    }

    // MARK: - Step encoding

    /// How a step is written. Both are in common use and Logic reads either,
    /// once its Expert view is told which — hence the choice.
    enum Step: String, CaseIterable, Identifiable {
        case signMagnitude, twosComplement
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .signMagnitude:  return "Sign magnitude (1–63 up, 65–127 down)"
            case .twosComplement: return "Two's complement (1–63 up, 127–65 down)"
            }
        }
        var logicFormat: String {
            switch self {
            case .signMagnitude:  return "Sign Magnitude"
            case .twosComplement: return "2's Complement"
            }
        }
    }

    static let stepKey = "mixerStepFormat"

    static var step: Step {
        UserDefaults.standard.string(forKey: stepKey).flatMap(Step.init) ?? .signMagnitude
    }

    /// The controller value for a movement of `ticks`, positive for up.
    static func value(forTicks ticks: Int, step: Step = MixerControl.step) -> UInt8 {
        let size = min(63, max(1, abs(ticks)))
        if ticks >= 0 { return UInt8(size) }
        switch step {
        case .signMagnitude:  return UInt8(64 + size)
        case .twosComplement: return UInt8(128 - size)
        }
    }
}
