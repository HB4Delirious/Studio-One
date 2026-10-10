import Combine
import Foundation

/// Whether the key Studio One sent is the key MetaTune shows, on Mic 1's
/// channel — read back through a second surface, `PluginDisplay.check`, in a
/// control surface group of its own locked to that channel. Logic says
/// nothing back to a sender about an assignment; a Mackie Control is told
/// what the plug-in is set to, so the check reads MetaTune's twelve switches
/// as MetaTune shows them and holds them to the key that went out.
///
/// It names a key that didn't land, with what MetaTune shows instead, once
/// the sweep has had time to arrive; and while Studio One walks Mic 1's
/// switches, each step in turn, so a switch learned wrongly shows up by name.
@MainActor
final class KeyCheck: ObservableObject {

    static let shared = KeyCheck()

    enum Status: Equatable {
        /// Turned off in Settings.
        case off
        /// Not reading MetaTune yet, and why.
        case notReady(String)
        /// Sent, still arriving.
        case waiting(String)
        case landed(String)
        case missed(expected: String, shows: String)
        /// MetaTune is bypassed on Mic 1's channel: a song with no key.
        case bypassed
    }

    @Published private(set) var status: Status = .off

    private var watches: Set<AnyCancellable> = []
    /// The send last logged, so each is reported once.
    private var reported: MIDIBridge.SentKey?
    /// The send being watched: judged when the next replaces it, if its time
    /// was up — a walk's steps come faster than the check looks.
    private var watching: MIDIBridge.SentKey?

    private init() {
        let display = PluginDisplay.check
        // Read after the change lands: @Published announces before it.
        display.objectWillChange
            .merge(with: MIDIBridge.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &watches)
        // A key that never arrives changes nothing; time alone turns waiting
        // into missed.
        Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.update() }
            .store(in: &watches)
    }

    private func update() {
        let display = PluginDisplay.check
        guard display.isEnabled else { return set(.off) }
        guard display.phase == .showing, let tuner = display.shownPlugin else {
            return set(.notReady(Self.why(display.phase)))
        }
        let readings = display.readings[tuner.name] ?? [:]
        var lit: Set<Int> = []
        var seen: Set<Int> = []
        var bypassed = false
        for (index, name) in tuner.controls.enumerated() {
            guard let value = readings[index]?.value else { continue }
            let on = value.caseInsensitiveCompare("On") == .orderedSame
            if name == "Bypass" {
                bypassed = on
            } else if let pitchClass = Self.pitchClass(of: name) {
                seen.insert(pitchClass)
                if on { lit.insert(pitchClass) }
            }
        }
        guard seen.count == 12 else { return set(.notReady("MetaTune's switches aren't read yet.")) }
        if bypassed { return set(.bypassed) }
        let latest = MIDIBridge.shared.sentKey
        if let earlier = watching, earlier != latest, Date() >= earlier.due.addingTimeInterval(-0.1) {
            judge(earlier, lit)
        }
        watching = latest
        guard let sent = latest else {
            return set(.notReady("MetaTune shows \(Self.describe(lit)); no key sent yet."))
        }
        if lit == sent.on {
            set(.landed(sent.name))
            report(sent, "MetaTune on Mic 1 shows \(sent.name)")
        } else if Date() < sent.due {
            set(.waiting(sent.name))
        } else {
            let shows = Self.describe(lit)
            set(.missed(expected: sent.name, shows: shows))
            report(sent, "sent \(sent.name), but MetaTune on Mic 1 shows \(shows) — the key didn't land")
        }
    }

    /// The verdict on a send the next one has replaced, for the log only.
    private func judge(_ sent: MIDIBridge.SentKey, _ lit: Set<Int>) {
        if lit == sent.on {
            report(sent, "MetaTune on Mic 1 shows \(sent.name)")
        } else {
            report(sent, "sent \(sent.name), but MetaTune on Mic 1 shows \(Self.describe(lit)) — the key didn't land")
        }
    }

    private func set(_ new: Status) {
        if status != new { status = new }
    }

    private func report(_ sent: MIDIBridge.SentKey, _ text: String) {
        guard reported != sent else { return }
        reported = sent
        Diagnostics.log("key check: " + text)
    }

    private static func why(_ phase: PluginDisplay.Phase) -> String {
        switch phase {
        case .off:             return "Off."
        case .waitingForLogic: return "Waiting for Logic."
        case .connected:       return "Connected; MetaTune not read yet."
        case .reading(let now): return now
        case .showing:         return "Reading MetaTune."
        case .failed(let why): return why
        }
    }

    // MARK: - Notes

    /// The pitch class a MetaTune switch stands for, by the name Logic gives
    /// it: "C", "C#/Db", "D#", "F#/Gb" … ; nil for any other control.
    static func pitchClass(of name: String) -> Int? {
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        let first = name.split(separator: "/").first.map(String.init) ?? name
        guard (1...2).contains(first.count), let letter = first.first, let natural = letters[letter] else { return nil }
        if first.count == 1 { return name.count <= 5 ? natural : nil }
        switch first.last {
        case "#": return (natural + 1) % 12
        case "b": return (natural + 11) % 12
        default:  return nil
        }
    }

    /// "D♯ minor / F♯ major" when the lit switches make a major scale, else
    /// the notes themselves.
    static func describe(_ lit: Set<Int>) -> String {
        if lit.isEmpty { return "no notes" }
        if let root = (0..<12).first(where: { PitchPlugin.notes(root: $0, minor: false) == lit }) {
            return "\(PitchPlugin.noteNames[root]) major / \(PitchPlugin.noteNames[(root + 9) % 12]) minor"
        }
        return lit.sorted().map { PitchPlugin.noteNames[$0] }.joined(separator: " ")
    }
}
