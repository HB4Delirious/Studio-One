import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Each singer's performance, recorded from an input of the host's choosing
/// — the mix from the interface, or a room mic — as an AAC file per song,
/// with a photo of the singer if the Mac has a camera. The break screen shows
/// a code for the song just sung; the singer's phone lists theirs. Off until
/// turned on in Settings › Recordings, and the lyrics screen says when it's
/// recording.
///
/// Kept in Application Support/Studio One/Performances, a folder per night,
/// for as many days as Settings says. Under thirty seconds isn't kept: a
/// song skipped is not a performance.
@MainActor
final class Performances: ObservableObject {
    static let shared = Performances()

    static let enabledKey = "recordPerformances"
    /// The input's unique ID; empty for the Mac's default input.
    static let deviceKey = "recordInput"
    /// The first of the two channels recorded, from 0.
    static let channelKey = "recordChannel"
    /// One channel, on both sides.
    static let monoKey = "recordMono"
    static let photoKey = "recordPhoto"
    /// The camera's unique ID; empty for the default.
    static let cameraKey = "recordCamera"
    /// 0 keeps them until deleted.
    static let keepDaysKey = "recordKeepDays"
    static let minimumSeconds = 30.0
    /// When in the song the photo is taken.
    static let photoAfter = 45.0

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var keepDays: Int { UserDefaults.standard.object(forKey: keepDaysKey) as? Int ?? 7 }

    struct Recording: Codable, Identifiable, Equatable {
        /// Random, and the handle in its web address.
        let id: String
        let uri: String
        let name: String
        let artist: String
        let singer: String?
        let started: Date
        let night: String
        /// Its files' name, without the extension: readable in Finder.
        let file: String
        var seconds: Double
        var hasPhoto: Bool

        var who: String { singer ?? name }
    }

    /// Newest first.
    @Published private(set) var recordings: [Recording] = []
    /// The song being recorded now.
    @Published private(set) var current: Recording?
    @Published private(set) var problem: String?

    private weak var model: KaraokeModel?
    private var engine: AVAudioEngine?
    private let writer = PerformanceWriter()
    private var timer: Timer?
    private var pausedSince: Date?
    private var engineStop: Task<Void, Never>?
    private var photo: Task<Void, Never>?

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio One/Performances", isDirectory: true)
    }
    nonisolated private static var index: URL { folder.appendingPathComponent("recordings.json") }

    func audioURL(_ recording: Recording) -> URL {
        Self.folder.appendingPathComponent(recording.night, isDirectory: true)
            .appendingPathComponent(recording.file + ".m4a")
    }

    func photoURL(_ recording: Recording) -> URL {
        Self.folder.appendingPathComponent(recording.night, isDirectory: true)
            .appendingPathComponent(recording.file + ".jpg")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.index),
           let saved = try? JSONDecoder().decode([Recording].self, from: data) {
            // Files deleted in Finder are gone from the list too.
            recordings = saved.filter { FileManager.default.fileExists(atPath: audioURL($0).path) }
        }
    }

    func start(model: KaraokeModel) {
        guard timer == nil else { return }
        self.model = model
        prune()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Performances.shared.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Lookups

    /// The latest recording of a song, made since `since`.
    func latest(for uri: String, since: Date) -> Recording? {
        recordings.first { $0.uri == uri && $0.started >= since }
    }

    /// Tonight's, by one singer, newest first.
    func tonight(by singer: String) -> [Recording] {
        let night = Setlists.night(for: Date())
        return recordings.filter { $0.night == night && $0.singer == singer }
    }

    func recording(id: String) -> Recording? { recordings.first { $0.id == id } }

    /// Its page on the request line, under the guest address.
    static func link(_ recording: Recording, from guestAddress: URL) -> URL {
        guestAddress.appendingPathComponent("p").appendingPathComponent(recording.id)
    }

    /// When it'll be deleted, or nil if it's kept.
    static func expiry(of recording: Recording) -> Date? {
        keepDays > 0 ? recording.started.addingTimeInterval(Double(keepDays) * 86_400) : nil
    }

    // MARK: - Recording

    /// Once a second: a song playing — not house music, not a break — is
    /// recorded; when it changes, the last one is finished.
    private func check() {
        guard let model else { return }
        let wanted = Self.isEnabled && model.intermission == nil && !model.fillerPlaying ? model.track : nil
        if let current, wanted?.uri != current.uri { finish() }
        guard let track = wanted else { return }

        if current == nil {
            // Started once it plays, so a song only cued isn't recorded.
            guard model.isPlaying else { return }
            begin(track)
            return
        }
        // Nothing written while paused; a long pause ends it.
        writer.paused = !model.isPlaying
        if model.isPlaying {
            pausedSince = nil
        } else if let since = pausedSince {
            if Date().timeIntervalSince(since) > 120 { finish() }
        } else {
            pausedSince = Date()
        }
    }

    private func begin(_ track: PlayerTrack) {
        guard let format = startEngine() else { return }
        let started = Date()
        let singer = RequestServer.shared.requester(name: track.name, artist: track.artist)
        let id = Self.makeID()
        let night = Setlists.night(for: started)
        let recording = Recording(id: id, uri: track.uri, name: track.name, artist: track.artist, singer: singer,
                                  started: started, night: night,
                                  file: Self.fileName(at: started, name: track.name, singer: singer, night: night),
                                  seconds: 0, hasPhoto: false)
        let url = audioURL(recording)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let mono = UserDefaults.standard.bool(forKey: Self.monoKey)
            let first = UserDefaults.standard.integer(forKey: Self.channelKey)
            try writer.begin(url, sampleRate: format.sampleRate, channels: (first, mono ? first : first + 1))
        } catch {
            problem = "Couldn't record: \(error.localizedDescription)"
            Diagnostics.log("recordings: " + (problem ?? ""))
            return
        }
        engineStop?.cancel()
        current = recording
        pausedSince = nil
        problem = nil
        Diagnostics.log("recordings: recording \(track.name)\(singer.map { " by \($0)" } ?? "")")

        if UserDefaults.standard.bool(forKey: Self.photoKey) {
            let target = photoURL(recording), camera = UserDefaults.standard.string(forKey: Self.cameraKey)
            photo = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.photoAfter))
                guard !Task.isCancelled, self?.current?.id == id else { return }
                let data = await Task.detached(priority: .utility) { await PhotoTaker().take(camera: camera) }.value
                guard let data, Self.saveJPEG(data, to: target) else { return }
                self?.photoTaken(id)
            }
        }
    }

    private func finish() {
        guard var recording = current else { return }
        current = nil
        photo?.cancel()
        recording.seconds = writer.finish()
        recording.hasPhoto = FileManager.default.fileExists(atPath: photoURL(recording).path)
        if recording.seconds < Self.minimumSeconds {
            try? FileManager.default.removeItem(at: audioURL(recording))
            try? FileManager.default.removeItem(at: photoURL(recording))
            Diagnostics.log("recordings: \(recording.name) not kept, \(Int(recording.seconds)) s")
        } else {
            recordings.insert(recording, at: 0)
            save()
            Diagnostics.log("recordings: kept \(recording.file), \(Int(recording.seconds)) s")
        }
        // Kept listening a moment, for a next song that starts at once.
        engineStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.current == nil else { return }
            self?.stopEngine()
        }
    }

    /// A photo that arrived after the song was finished still belongs to it.
    private func photoTaken(_ id: String) {
        if current?.id == id { current?.hasPhoto = true }
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            recordings[index].hasPhoto = true
            save()
        }
    }

    /// Quitting: the song so far is kept, if long enough.
    func shutDown() {
        finish()
        stopEngine()
    }

    /// When recording is switched off mid-song, what's there is kept (if
    /// long enough).
    func settingsChanged() {
        if !Self.isEnabled { finish() }
        prune()
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: audioURL(recording))
        try? FileManager.default.removeItem(at: photoURL(recording))
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    /// Older than Settings keeps: gone, with any night's folder left empty.
    private func prune() {
        let days = Self.keepDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = recordings.filter { $0.started < cutoff }
        guard !old.isEmpty else { return }
        for recording in old { delete(recording) }
        for night in Set(old.map(\.night)) {
            let folder = Self.folder.appendingPathComponent(night, isDirectory: true)
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        Diagnostics.log("recordings: deleted \(old.count) older than \(days) days")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(recordings).write(to: Self.index, options: .atomic)
    }

    // MARK: - The input

    /// The input's format, with the tap writing to `writer`; nil if it
    /// can't listen.
    private func startEngine() -> AVAudioFormat? {
        if let engine { return engine.inputNode.outputFormat(forBus: 0) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            problem = "Microphone access is off for Studio One — turn it on in System Settings › Privacy & Security › Microphone."
            return nil
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let uid = UserDefaults.standard.string(forKey: Self.deviceKey) ?? ""
        if !uid.isEmpty, let device = Applause.inputDevices().first(where: { $0.uid == uid }), let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No input to record from. Pick one in Settings › Recordings."
            return nil
        }
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in writer.write(buffer) }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't record: \(error.localizedDescription)"
            Diagnostics.log("recordings: " + (problem ?? ""))
            return nil
        }
        self.engine = engine
        return format
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    // MARK: - Names

    private static func makeID() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }

    nonisolated private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH.mm"
        return formatter
    }()

    /// "21.42 Dancing Queen — Sam", unique in its night's folder.
    nonisolated static func fileName(at date: Date, name: String, singer: String?, night: String) -> String {
        let time = timeFormat.string(from: date)
        var base = "\(time) \(name)" + (singer.map { " — \($0)" } ?? "")
        base = String(base.map { "/:\\".contains($0) ? "-" : $0 }.prefix(120))
        let folder = folder.appendingPathComponent(night, isDirectory: true)
        var candidate = base, number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate + ".m4a").path) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    /// The camera's photo, at most 1600 pixels across, as a JPEG.
    nonisolated static func saveJPEG(_ data: Data, to url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

/// Writes the tap's audio to the song's file, from the audio thread: two of
/// the input's channels, as stereo AAC.
final class PerformanceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var rate = 48_000.0
    private var channels = (0, 1)
    private var isPaused = false

    var paused: Bool {
        get { lock.withLock { isPaused } }
        set { lock.withLock { isPaused = newValue } }
    }

    func begin(_ url: URL, sampleRate: Double, channels: (Int, Int)) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            self.file = file
            frames = 0
            rate = sampleRate
            self.channels = channels
            isPaused = false
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, !isPaused, let source = buffer.floatChannelData else { return }
        let count = Int(buffer.format.channelCount), length = buffer.frameLength
        guard length > 0, count > 0,
              let stereo = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: length),
              let target = stereo.floatChannelData else { return }
        stereo.frameLength = length
        target[0].update(from: source[min(channels.0, count - 1)], count: Int(length))
        target[1].update(from: source[min(channels.1, count - 1)], count: Int(length))
        do {
            try file.write(from: stereo)
            frames += AVAudioFramePosition(length)
        } catch {
            Diagnostics.log("recordings: write failed: \(error.localizedDescription)")
            self.file = nil
        }
    }

    /// Closes the file; how long it is, in seconds.
    func finish() -> Double {
        lock.withLock {
            let seconds = Double(frames) / rate
            file = nil
            frames = 0
            return seconds
        }
    }
}

/// One photo from a camera: the session runs just long enough for the
/// exposure to settle — the camera's light shows for two or three seconds.
final class PhotoTaker: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Data?, Never>?

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    func take(camera uid: String?) async -> Data? {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = uid.flatMap({ $0.isEmpty ? nil : AVCaptureDevice(uniqueID: $0) })
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        let session = AVCaptureSession()
        session.sessionPreset = .photo
        let output = AVCapturePhotoOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        defer { session.stopRunning() }
        try? await Task.sleep(for: .seconds(1.5))

        return await withCheckedContinuation { continuation in
            lock.withLock { waiting = continuation }
            output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]),
                                delegate: self)
            // A camera that never answers doesn't hold the song's photo up.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [self] in finish(nil) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        finish(error == nil ? photo.fileDataRepresentation() : nil)
    }

    private func finish(_ data: Data?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(returning: data)
    }
}
