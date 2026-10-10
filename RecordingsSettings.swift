import AVFoundation
import AppKit
import CoreAudio
import SwiftUI

/// Settings › Recordings: what's recorded and from where, the photo, how long
/// they're kept, and tonight's.
struct RecordingsSettings: View {
    @ObservedObject private var performances = Performances.shared
    @ObservedObject private var requests = RequestServer.shared
    @AppStorage(Performances.enabledKey) private var enabled = false
    @AppStorage(Performances.deviceKey) private var device = ""
    @AppStorage(Performances.channelKey) private var channel = 0
    @AppStorage(Performances.monoKey) private var mono = false
    @AppStorage(Performances.photoKey) private var photo = false
    @AppStorage(Performances.cameraKey) private var camera = ""
    @AppStorage(Performances.keepDaysKey) private var keepDays = 7
    @State private var inputs: [Applause.Input] = []
    @State private var cameras: [(id: String, name: String)] = []
    @State private var pendingDelete: Performances.Recording?
    @State private var access = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Recordings")

            SettingsSection("Recording", info: "Each song sung is recorded from the input here — your interface's mix (a loopback or monitor output into a spare input) sounds best; the Mac's microphone records the room. One file per song, stereo AAC, starting when the song plays and ending when it does; skipped songs under thirty seconds aren't kept. Nothing is recorded during breaks or house music. While it records, the lyrics screen shows ● REC in its corner — tell the room.") {
                Toggle("Record each singer", isOn: $enabled)
                    .font(.system(size: 12, design: .rounded))
                LabelledRow("Input:") {
                    Picker("Input", selection: $device) {
                        Text("The Mac's default input").tag("")
                        ForEach(inputs) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden().fixedSize()
                }
                LabelledRow("Channels:") {
                    Picker("Channels", selection: $channel) {
                        ForEach(Array(stride(from: 0, to: channelCount, by: mono ? 1 : 2)), id: \.self) { first in
                            Text(mono || first + 1 >= channelCount ? "\(first + 1)" : "\(first + 1)–\(first + 2)").tag(first)
                        }
                    }
                    .labelsHidden().fixedSize()
                    Toggle("Mono", isOn: $mono)
                        .font(.system(size: 12, design: .rounded))
                }
                if enabled { StatusLine(status) }
            }

            SettingsSection("Photo", info: "About \(Int(Performances.photoAfter)) seconds into each song, Studio One takes one photo from the camera — point it at the stage. The camera's light shows for two or three seconds. The photo goes on the singer's page with the recording. macOS asks once for the camera.") {
                Toggle("Take a photo of each singer", isOn: $photo)
                    .font(.system(size: 12, design: .rounded))
                if photo {
                    LabelledRow("Camera:") {
                        Picker("Camera", selection: $camera) {
                            Text("The default camera").tag("")
                            ForEach(cameras, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }

            SettingsSection("Keeping them", info: "With the request line on, the break after each song shows a code for its recording, and the singer's phone lists theirs under their name — to play, or save to the phone. They're kept on this Mac, a folder per night, for as long as you choose here; older ones are deleted when Studio One starts.") {
                LabelledRow("Keep for:") {
                    Picker("Keep for", selection: $keepDays) {
                        Text("1 day").tag(1)
                        Text("3 days").tag(3)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("Until I delete them").tag(0)
                    }
                    .labelsHidden().fixedSize()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Performances.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Performances.folder)
                    }
                    .controlSize(.small)
                }
                if enabled, requests.guestAddress == nil {
                    Text("The request line is off, so singers can't take theirs home from their phones tonight.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }

            SettingsSection("Tonight") {
                let tonight = performances.recordings.filter { $0.night == Setlists.night(for: Date()) }
                if tonight.isEmpty {
                    Text("Nothing recorded tonight.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                ForEach(tonight) { recording in
                    HStack(spacing: 8) {
                        Text(recording.started.formatted(date: .omitted, time: .shortened))
                            .font(Theme.timecode).foregroundStyle(Theme.secondary)
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(recording.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text([recording.singer, recording.artist].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if recording.hasPhoto {
                            Image(systemName: "camera.fill").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                .help("With a photo")
                        }
                        Text(Duration.seconds(recording.seconds.rounded()).formatted(.time(pattern: .minuteSecond)))
                            .font(Theme.timecode).foregroundStyle(Theme.secondary)
                        Button("Play") { NSWorkspace.shared.open(performances.audioURL(recording)) }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([performances.audioURL(recording)])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Show in Finder")
                        Button {
                            pendingDelete = recording
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete this recording")
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            inputs = Applause.inputDevices()
            cameras = PhotoTaker.cameras().map { ($0.uniqueID, $0.localizedName) }
            checkAccess()
        }
        .onChange(of: enabled) { _, on in
            if on, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { checkAccess() } }
                }
            }
            performances.settingsChanged()
            checkAccess()
        }
        .onChange(of: photo) { _, on in
            if on, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { checkAccess() } }
                }
            }
            checkAccess()
        }
        .onChange(of: device) { _, _ in channel = 0 }
        .onChange(of: mono) { _, isMono in if !isMono { channel -= channel % 2 } }
        .onChange(of: keepDays) { _, _ in performances.settingsChanged() }
        .confirmationDialog("Delete this recording?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let recording = pendingDelete { performances.delete(recording) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map { "“\($0.name)”\($0.singer.map { " by \($0)" } ?? ""), with its photo. It goes for good, and its page stops working." } ?? "")
        }
    }

    /// The chosen input's channels; two when it can't be read.
    private var channelCount: Int {
        let id = device.isEmpty ? Self.defaultInput() : inputs.first { $0.uid == device }?.id
        return max(1, id.map(Applause.inputChannels) ?? 2)
    }

    private var status: String {
        if !access.isEmpty { return access }
        if let problem = performances.problem { return problem }
        if let current = performances.current {
            return "Recording “\(current.name)”\(current.singer.map { " by \($0)" } ?? "") now."
        }
        return "Ready: the next song is recorded when it plays."
    }

    private func checkAccess() {
        var problems: [String] = []
        if enabled, AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            problems.append("Microphone access is off for Studio One — System Settings › Privacy & Security › Microphone.")
        }
        if enabled, photo, AVCaptureDevice.authorizationStatus(for: .video) == .denied {
            problems.append("Camera access is off for Studio One — System Settings › Privacy & Security › Camera.")
        }
        access = problems.joined(separator: " ")
    }

    private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }
}

/// In the Controls window while a song is being recorded: what, by whom, and
/// for how long so far.
struct RecordingLine: View {
    @ObservedObject private var performances = Performances.shared

    var body: some View {
        if let current = performances.current {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("Recording\(current.singer.map { " \($0)" } ?? "")")
                        .font(.system(size: 11, weight: .semibold))
                    Text(Duration.seconds(context.date.timeIntervalSince(current.started).rounded(.down))
                            .formatted(.time(pattern: .minuteSecond)))
                        .font(Theme.timecode).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let problem = performances.problem, Performances.isEnabled {
            Label(problem, systemImage: "record.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
