import SwiftUI

/// Settings › Rig check: live status, a test key, a checklist to run through
/// on the rig itself — the parts only visible in Logic and on the Stream Deck
/// — then the backups of what Logic has learned, and the log.
struct RigCheckPanel: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @AppStorage(PitchPlugin.defaultsKey) private var pitchPlugin: PitchPlugin = .original
    @AppStorage(PitchPlugin.tunerCountKey) private var tunerCount = 1
    @AppStorage(Self.doneKey) private var doneRaw = ""
    @State private var swallowers: [LogicAssignments.Swallower] = []
    @State private var wrongPorts: [LogicAssignments.WrongPort] = []

    static let doneKey = "rigCheckDone"

    private static let steps: [(id: String, text: String)] = [
        ("learn", "Learn MetaTune's twelve note switches for every mic (Settings › Logic, pick each mic under Send for Learn)."),
        ("dminor", "Send a test key, above: D minor — every MetaTune should light D E F G A A♯ C and nothing else. If it's backwards, turn on “Notes arrive inverted”."),
        ("change", "Skip between two songs in different keys: only the new song's key reaches MetaTune, on every mic."),
        ("nokey", "Learn Bypass for each mic (Settings › Logic), then skip to a song with no key: every tuner bypasses. Type a key in, or skip to a song that has one: they come back on."),
        ("songsettings", "If you use per-song settings, set one for a song and skip to it: MetaTune follows."),
        ("playlist", "Start a song from a playlist in Controls: it plays, and the next song follows on."),
        ("requests", "Request line: queue two songs from a phone, press “Play the Requests” — both play, in order."),
        ("upnext", "In the last thirty seconds of a requested song, the lyrics screen shows who's up next."),
        ("seek", "Pause a song, click a lyric line or turn the seek dial: the lyrics follow."),
        ("tempo", "Tempo: learn it (Settings › Logic, Show tip beside Tempo), then “Send This Song's Tempo” — Logic shows the song's tempo, to the whole BPM."),
        ("walk", "Walk the Switches for each mic: every MetaTune key lights in turn, C to B."),
        ("display", "Plug-in display: in Logic's Control Surface Setup, untick Open/Close Plug-in Window and Follows Focused View, select Topline's channel, tick Track Lock. Settings › Plug-ins: read the plug-ins, tick what to show. Turn an M-BRIO knob: the Controls window follows."),
        ("deck", "Stream Deck +: turn each mic dial and press it to mute — with Studio One open, then with it closed."),
        ("timing", "Time the lyrics for one song with Time Lyrics, and check they land."),
        ("backup", "Quit Logic once everything is learned, then Back Up Now (below)."),
    ]

    private var done: Set<String> { Set(doneRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ id: String) {
        var set = done
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        doneRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneTitle("Rig check")

            SettingsSection("Right now") {
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
                status(swallowers.isEmpty, "Keys Logic swallows",
                       swallowers.isEmpty ? "none"
                           : "\(swallowers.count) assignment\(swallowers.count == 1 ? "" : "s") to delete — see Send a test key")
                status(wrongPorts.isEmpty, "Control surface ports",
                       wrongPorts.isEmpty ? "none on Studio One's key and tempo port"
                           : wrongPorts.map(\.surface).joined(separator: ", ") + " on “Studio One”")
                ForEach(wrongPorts, id: \.surface) { wrong in
                    Text(wrong.warning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                if let culprit = AutoQuitWatch.culprit {
                    status(false, "Auto-quit", "\(culprit) quits Studio One when its windows close")
                }
            }

            LogicCheckSection(swallowers: swallowers)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("REHEARSAL, ON THE RIG").font(Theme.label).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("\(done.count) of \(Self.steps.count)").font(Theme.label).foregroundStyle(Theme.secondary)
                    Button("Start Again") { doneRaw = "" }.controlSize(.small)
                }
                ForEach(Self.steps, id: \.id) { step in
                    Button { toggle(step.id) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: done.contains(step.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(done.contains(step.id) ? Theme.cue : Theme.secondary)
                            Text(step.text)
                                .font(.system(size: 12))
                                .foregroundStyle(done.contains(step.id) ? Theme.secondary : .white)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            LogicBackupSettings()
            UpdateSettings()
            LogSection()
        }
        .task {
            swallowers = await Task.detached(priority: .utility) { LogicAssignments.swallowers() }.value
            wrongPorts = await Task.detached(priority: .utility) { LogicAssignments.wrongPorts() }.value
        }
    }

    private func status(_ good: Bool, _ label: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(good ? Theme.cue : .orange)
            Text(label).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }
}
