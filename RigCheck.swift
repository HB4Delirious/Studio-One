import SwiftUI

/// Settings › Rig check: what can be seen from here, live, and a rehearsal
/// checklist for what can only be seen in Logic and on the Stream Deck.
///
/// The code for most of this was proved on a Mac without Logic, a Stream
/// Deck + or music playing; this is the list to run through once on the rig
/// itself before a party depends on it.
struct RigCheckPanel: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @AppStorage(PitchPlugin.defaultsKey) private var pitchPlugin: PitchPlugin = .original
    @AppStorage(PitchPlugin.tunerCountKey) private var tunerCount = 1
    @AppStorage(Self.doneKey) private var doneRaw = ""

    static let doneKey = "rigCheckDone"

    private static let steps: [(id: String, text: String)] = [
        ("learn", "Learn MetaTune's twelve note switches for every mic (Settings › Logic, pick each mic under Send for Learn)."),
        ("dminor", "Check it: send D minor — every MetaTune should light D E F G A A♯ C and nothing else. If it's backwards, turn on “Notes arrive inverted”."),
        ("change", "Skip between two songs in different keys: only the new song's key reaches MetaTune, on every mic."),
        ("songsettings", "If you use per-song settings, set one for a song and skip to it: MetaTune follows."),
        ("playlist", "Start a song from a playlist in Controls: it plays, and the next song follows on."),
        ("requests", "Request line: queue two songs from a phone, press “Play the requests” — both play, in order."),
        ("upnext", "In the last thirty seconds of a requested song, the lyrics screen shows who's up next."),
        ("seek", "Pause a song, click a lyric line or turn the seek dial: the lyrics follow."),
        ("deck", "Stream Deck +: turn each mic dial and press it to mute — with Studio One open, then with it closed."),
        ("timing", "Time the lyrics for one song with the hand button, and check they land."),
        ("backup", "Quit Logic once everything is learned, then Back up now (Settings › Logic)."),
    ]

    private var done: Set<String> { Set(doneRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ id: String) {
        var set = done
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        doneRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rig check").font(.system(size: 16, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 6) {
                Text("RIGHT NOW").font(Theme.label).foregroundStyle(Theme.upcoming)
                status(model.connection == .ready, "\(model.musicSource.displayName)",
                       model.connection == .ready ? "connected" : "not answering — is it open?")
                status(midiEnabled, "Key and tempo to Logic", midiEnabled ? "on" : "off (Settings › Logic)")
                status(true, "Tuner", "\(pitchPlugin.displayName), \(tunerCount) mic\(tunerCount == 1 ? "" : "s")")
                status(ControlServer.shared.port != nil, "Stream Deck connection",
                       ControlServer.shared.port.map { "listening on port \(String($0))" } ?? "not running")
                let backup = LogicBackup.backups().first
                status(backup != nil || !LogicBackup.sourceExists, "Logic's assignments",
                       backup.map { "last copied \(LogicBackup.label(for: $0))" }
                           ?? (LogicBackup.sourceExists ? "never backed up" : "Logic isn't on this Mac"))
                if let culprit = AutoQuitWatch.culprit {
                    status(false, "Auto-quit", "\(culprit) quits Studio One when its windows close")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("REHEARSAL, ON THE RIG").font(Theme.label).foregroundStyle(Theme.upcoming)
                    Spacer()
                    Text("\(done.count) of \(Self.steps.count)").font(Theme.label).foregroundStyle(Theme.upcoming)
                    Button("Start again") { doneRaw = "" }.controlSize(.small)
                }
                ForEach(Self.steps, id: \.id) { step in
                    Button { toggle(step.id) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: done.contains(step.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done.contains(step.id) ? Theme.cue : Theme.upcoming)
                            Text(step.text)
                                .font(.system(size: 12))
                                .foregroundStyle(done.contains(step.id) ? Theme.upcoming : .white)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func status(_ good: Bool, _ label: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(good ? Theme.cue : .orange)
            Text(label).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.upcoming)
        }
    }
}
