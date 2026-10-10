import AVFoundation
import CoreAudio
import Foundation

/// The applause meter: the room's cheer for the song just sung, measured on a
/// microphone for the first seconds of the break between songs, shown on the
/// lyrics screen as it rises, then as a score out of 100 — kept with the song
/// in the night's history, for a leaderboard.
///
/// It listens only while measuring, or while Settings shows its level, and
/// keeps nothing but the score. The loudest stretch counts, not the average,
/// so a cheer that dies down isn't marked down for it; what reads as silence
/// is set once in Settings, against the room.
@MainActor
final class Applause: ObservableObject {

    static let shared = Applause()

    static let enabledKey = "applauseMeter"
    /// The input's unique ID; empty for the Mac's default input.
    static let deviceKey = "applauseInput"
    /// The level, in dBFS, that counts as a quiet room: 0 points.
    static let floorKey = "applauseFloor"
    static let defaultFloor = -50.0
    /// From the floor to full marks.
    static let span = 35.0
    /// How long the cheer is listened to.
    static let window = 8.0

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var floor: Double {
        UserDefaults.standard.object(forKey: floorKey) as? Double ?? defaultFloor
    }

    enum Phase: Equatable {
        case idle
        /// For whom: the singer, else the song.
        case listening(for: String, until: Date)
        case scored(Int, for: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 0…1, live, while listening or monitoring.
    @Published private(set) var level: Double = 0
    /// Why it can't listen: microphone access, no input.
    @Published private(set) var problem: String?

    private var engine: AVAudioEngine?
    private var samples: [Double] = []
    private var listeningSince = Date.distantPast
    private var measuring: (uri: String, who: String)?
    /// The song being cheered, for anything keeping score (see `PartyGames`).
    private var measuringSong: (name: String, artist: String)?
    private var finish: Task<Void, Never>?
    private var monitors = 0

    // MARK: - Measuring

    /// Listens to the room for the song a break follows.
    func measure(for pause: Intermission) {
        guard Self.isEnabled else { return }
        let who = pause.singer ?? pause.endedName
        measuring = (pause.endedURI, who)
        measuringSong = (pause.endedName, pause.endedArtist)
        samples = []
        listeningSince = Date()
        phase = .listening(for: who, until: Date().addingTimeInterval(Self.window))
        withMicrophone { [weak self] in
            guard let self, self.measuring?.uri == pause.endedURI else { return }
            guard self.startEngine() else { return self.cancelMeasuring() }
        }
        finish?.cancel()
        finish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.window))
            guard !Task.isCancelled else { return }
            self?.conclude()
        }
    }

    /// The break ended: a cheer long enough to count is scored; otherwise
    /// it's dropped.
    func stop() {
        finish?.cancel()
        if measuring != nil { conclude() }
        if case .scored = phase { phase = .idle }
    }

    private func conclude() {
        guard let (uri, who) = measuring else { return }
        measuring = nil
        stopEngineUnlessMonitoring()
        guard Date().timeIntervalSince(listeningSince) >= 2, !samples.isEmpty else {
            return cancelMeasuring()
        }
        let score = Self.score(samples)
        phase = .scored(score, for: who)
        Setlists.shared.setApplause(score, for: uri)
        if let song = measuringSong {
            NotificationCenter.default.post(name: .applauseScored, object: nil,
                                            userInfo: ["name": song.name, "artist": song.artist, "score": score])
        }
        Diagnostics.log("applause: \(score) for \(who)")
    }

    private func cancelMeasuring() {
        measuring = nil
        phase = .idle
        stopEngineUnlessMonitoring()
    }

    /// The top 40% of the moments heard, averaged, above the floor.
    static func score(_ samples: [Double]) -> Int {
        let loudest = samples.sorted(by: >).prefix(max(1, samples.count * 2 / 5))
        let level = loudest.reduce(0, +) / Double(loudest.count)
        return Int((min(1, max(0, (level - floor) / span)) * 100).rounded())
    }

    /// Tonight's best cheers, loudest first.
    static func leaderboard(limit: Int = 3) -> [SetlistEntry] {
        Setlists.shared.entries(Setlists.night(for: Date()))
            .filter { $0.applause != nil }
            .sorted { ($0.applause ?? 0) > ($1.applause ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Monitoring, for Settings

    /// The live level, to set the floor against the room.
    func startMonitoring() {
        monitors += 1
        guard monitors == 1 else { return }
        withMicrophone { [weak self] in
            guard let self, self.monitors > 0, self.engine == nil else { return }
            _ = self.startEngine()
        }
    }

    func stopMonitoring() {
        monitors = max(0, monitors - 1)
        stopEngineUnlessMonitoring()
    }

    /// A new input or floor: start over on it.
    func restart() {
        guard engine != nil else { return }
        stopEngine()
        _ = startEngine()
    }

    // MARK: - The input

    private func withMicrophone(_ then: @escaping @MainActor () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            problem = nil
            then()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let applause = Applause.shared
                        if granted { applause.problem = nil; then() } else { applause.denied() }
                    }
                }
            }
        default:
            denied()
        }
    }

    private func denied() {
        problem = "Microphone access is off for Studio One — turn it on in System Settings › Privacy & Security › Microphone."
        cancelMeasuring()
    }

    private func startEngine() -> Bool {
        guard engine == nil else { return true }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let uid = UserDefaults.standard.string(forKey: Self.deviceKey) ?? ""
        if !uid.isEmpty, let device = Self.inputDevices().first(where: { $0.uid == uid }), let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        // The node's output side, which a tap must match — after a change of
        // device the input side can differ, and a mismatch is an exception.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No input to listen on. Pick one in Settings › Between Songs."
            return false
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
            guard frames > 0 else { return }
            var energy: Float = 0
            for channel in 0..<count {
                let data = channels[channel]
                for frame in 0..<frames { energy += data[frame] * data[frame] }
            }
            let decibels = 20 * log10(max(1e-7, sqrt(energy / Float(frames * count))))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Applause.shared.heard(Double(decibels)) }
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't listen: \(error.localizedDescription)"
            Diagnostics.log("applause: " + (problem ?? ""))
            return false
        }
        self.engine = engine
        problem = nil
        return true
    }

    private func heard(_ decibels: Double) {
        let now = min(1, max(0, (decibels - Self.floor) / Self.span))
        // Up at once, down gently, like a meter's needle.
        level = max(now, level * 0.88)
        if measuring != nil { samples.append(decibels) }
    }

    private func stopEngineUnlessMonitoring() {
        guard monitors == 0, measuring == nil else { return }
        stopEngine()
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }

    // MARK: - Inputs

    struct Input: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Every device with an input: the Mac's microphone, an interface's inputs.
    static func inputDevices() -> [Input] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = text(id, kAudioDevicePropertyDeviceUID),
                  let name = text(id, kAudioObjectPropertyName) else { return nil }
            return Input(id: id, uid: uid, name: name)
        }
    }

    static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func text(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
