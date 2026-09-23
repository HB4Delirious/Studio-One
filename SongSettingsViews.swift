import SwiftUI

/// The Controls window's "Song settings" popover: a slider per named song
/// control, set for the song that's playing.
struct SongSettingsPopover: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This song's settings").font(.system(size: 14, weight: .semibold))
            Text(model.track?.name ?? "Nothing playing")
                .font(.system(size: 11)).foregroundStyle(Theme.upcoming).lineLimit(1)

            if SongControl.active.isEmpty {
                Text("Nothing set up yet. Name the plug-in controls you want to change per song in Settings › Logic › Per-song settings, and learn each one in Logic.")
                    .font(.system(size: 12)).foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(SongControl.active, id: \.self) { slot in
                    row(slot)
                }
                Text(midiEnabled
                     ? "Saved for this song and sent each time it starts. Songs you haven't set use the default."
                     : "Turn on “Send key and tempo as MIDI” in Settings › Logic for these to reach Logic.")
                    .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row(_ slot: Int) -> some View {
        let current = model.songControl(slot)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(SongControl.names[slot]).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(current.value.map(String.init) ?? "—")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text(current.isOwn ? "this song" : "default")
                    .font(.system(size: 10)).foregroundStyle(Theme.upcoming)
                    .frame(width: 52, alignment: .leading)
            }
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(current.value ?? 64) },
                    set: { model.setSongControl(slot, to: Int($0.rounded())) }),
                       in: 0...127)
                    .disabled(model.track == nil)
                Button("Default") { model.setSongControl(slot, to: nil) }
                    .controlSize(.small)
                    .disabled(!current.isOwn)
                    .help("Forget this song's value and use the default")
            }
        }
    }
}

/// Settings › Logic: naming the song controls, their defaults, and Learn.
struct SongControlSettings: View {
    @AppStorage(MIDIBridge.enabledKey) private var midiEnabled = false
    @State private var names = SongControl.names
    @State private var defaults: [String] = (0..<SongControl.count).map {
        SongControl.defaultValue($0).map(String.init) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PER-SONG SETTINGS").font(Theme.label).foregroundStyle(Theme.upcoming)
            Text("Plug-in settings that change with the song — MetaTune's retune speed or humanize, a reverb send. Name a control, press Learn with Logic's Controller Assignments in Learn Mode and the parameter touched, then set values per song from the sliders button in the Controls window. Each is sent as the song starts, on channel \(SongControl.channel + 1). Leave a default empty to send nothing for songs without their own value.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(0..<SongControl.count, id: \.self) { slot in
                HStack(spacing: 6) {
                    Text("CC \(SongControl.cc(slot))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.upcoming)
                        .frame(width: 40, alignment: .leading)
                    TextField("Unused", text: $names[slot])
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onChange(of: names[slot]) { _, _ in SongControl.names = names }
                    TextField("Default", text: $defaults[slot])
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .help("0–127, sent for songs that have no value of their own. Empty sends nothing.")
                        .onChange(of: defaults[slot]) { _, text in
                            SongControl.setDefault(Int(text.trimmingCharacters(in: .whitespaces)), slot: slot)
                        }
                    Button("Learn") {
                        MIDIBridge.shared.sendSongControlForLearn(
                            slot: slot, settle: Int(defaults[slot]) ?? 64)
                    }
                    .disabled(names[slot].trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
        }
        .disabled(!midiEnabled)
    }
}

/// Settings › Logic: copies of Logic's controller assignments.
struct LogicBackupSettings: View {
    @State private var backups = LogicBackup.backups()
    @State private var message: String?
    @State private var pendingRestore: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOGIC'S ASSIGNMENTS").font(Theme.label).foregroundStyle(Theme.upcoming)
            Text("Everything learned in Logic — key, MetaTune's switches, the dials, the song settings — lives in one file that a reset or a new Mac loses. Studio One copies it each time it starts, whenever it has changed, and keeps the last thirty. Logic writes the file when it quits, so quit Logic before backing up to catch the latest.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Back up now") {
                    message = LogicBackup.backUp() ?? "Backed up."
                    backups = LogicBackup.backups()
                }
                .disabled(!LogicBackup.sourceExists)
                Menu("Restore…") {
                    ForEach(backups, id: \.self) { backup in
                        Button(LogicBackup.label(for: backup)) { pendingRestore = backup }
                    }
                }
                .fixedSize()
                .disabled(backups.isEmpty)
                Button("Show backups") { NSWorkspace.shared.open(LogicBackup.folder) }
            }
            .controlSize(.small)
            Text(message ?? (LogicBackup.sourceExists
                             ? (backups.first.map { "Latest copy: \(LogicBackup.label(for: $0))" } ?? "No copies yet.")
                             : "Logic's assignments file isn't on this Mac."))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.upcoming)
        }
        .confirmationDialog("Restore Logic's assignments?", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("Restore") {
                if let backup = pendingRestore {
                    message = LogicBackup.restore(backup) ?? "Restored. Open Logic to use them."
                    backups = LogicBackup.backups()
                }
                pendingRestore = nil
            }
        } message: {
            Text("This replaces Logic's current assignments with the copy from \(pendingRestore.map(LogicBackup.label(for:)) ?? ""). What's there now is kept as a copy first.")
        }
    }
}
