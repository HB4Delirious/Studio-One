import Foundation

/// The room's lights, over DMX: low in the cover's colours while someone
/// sings, pulsing on the beat; bright during a break, following the cheer
/// while the applause meter listens; breathing gently under house music; a
/// slow drift of colour on standby. Settings › Lights sets it up.
@MainActor
final class LightShow: ObservableObject {
    static let shared = LightShow()

    static let enabledKey = "lights"
    static let portKey = "lightsPort"
    static let interfaceKey = "lightsInterface"
    /// Percent.
    static let masterKey = "lightsMaster"
    static let blackoutKey = "lightsBlackout"
    static let pulseKey = "lightsPulse"
    static let fixturesKey = "lightsFixtures"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var master: Double {
        (UserDefaults.standard.object(forKey: masterKey) as? Double ?? 100) / 100
    }
    static var pulses: Bool { UserDefaults.standard.object(forKey: pulseKey) as? Bool ?? true }

    enum Status: Equatable {
        case off
        case noPort
        case sending(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published var fixtures: [DMX.Fixture] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(fixtures), forKey: Self.fixturesKey)
        }
    }
    /// Each fixture's light, ten times a second while Settings shows them.
    @Published private(set) var preview: [UUID: DMX.Light] = [:]
    /// A test colour held on every fixture (or one, to find it), for a while.
    @Published private(set) var testing: (light: DMX.Light, only: UUID?)?

    var previewing = 0

    private weak var model: KaraokeModel?
    private var port: DMXPort?
    private var timer: Timer?
    private var retry: Task<Void, Never>?
    private var testEnds: Task<Void, Never>?
    /// Each fixture's colour as last sent, eased towards the scene's.
    private var shown: [UUID: DMX.Light] = [:]
    private var lastTick = Date()
    private var lastPreview = Date.distantPast
    private var cheer = 0.0

    private init() {
        fixtures = UserDefaults.standard.data(forKey: Self.fixturesKey)
            .flatMap { try? JSONDecoder().decode([DMX.Fixture].self, from: $0) } ?? []
    }

    func start(model: KaraokeModel) {
        self.model = model
        configure()
    }

    /// After any setting changes: opens, reopens or closes the port.
    func configure() {
        retry?.cancel()
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: Self.portKey) ?? ""
        let interface = defaults.string(forKey: Self.interfaceKey).flatMap(DMX.Interface.init) ?? .enttecPro

        guard Self.isEnabled else {
            stopPort()
            status = .off
            timer?.invalidate()
            timer = nil
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
                MainActor.assumeIsolated { LightShow.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if let port, port.path == path, port.interface == interface { return }
        stopPort()
        guard !path.isEmpty else { status = .noPort; return }
        do {
            port = try DMXPort(path: path, interface: interface) { message in
                Task { @MainActor in LightShow.shared.lost(path, message) }
            }
            status = .sending(path)
            Diagnostics.log("lights: sending to \(path) (\(interface.title))")
        } catch {
            status = .failed(error.localizedDescription)
            Diagnostics.log("lights: couldn't open \(path): \(error.localizedDescription)")
            retryLater()
        }
    }

    /// Unplugged, or the interface stopped: try again every few seconds.
    private func lost(_ path: String, _ message: String) {
        guard port?.path == path else { return }
        stopPort()
        status = .failed(message)
        Diagnostics.log("lights: lost \(path): \(message)")
        retryLater()
    }

    private func retryLater() {
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.configure()
        }
    }

    /// Quitting: lights out, and the port let go.
    func shutDown() {
        timer?.invalidate()
        timer = nil
        retry?.cancel()
        stopPort()
    }

    private func stopPort() {
        if let port {
            // Lights out before letting go, rather than frozen mid-song.
            port.send([UInt8](repeating: 0, count: DMX.universe))
            Thread.sleep(forTimeInterval: 0.05)
            port.close()
        }
        port = nil
    }

    /// Holds a colour on every fixture — or only `fixture`, to find it —
    /// for six seconds. Nil goes back to the show.
    func test(_ light: DMX.Light?, only fixture: UUID? = nil) {
        testEnds?.cancel()
        testing = light.map { ($0, fixture) }
        guard light != nil else { return }
        testEnds = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.testing = nil
        }
    }

    // MARK: - The show

    enum Scene: Equatable {
        case standby
        case song(playing: Bool)
        case houseMusic
        /// With the cheer's level, 0…1, while the applause meter listens.
        case intermission(cheer: Double?)
    }

    private func tick() {
        let now = Date()
        let elapsed = min(0.2, now.timeIntervalSince(lastTick))
        lastTick = now

        let scene = currentScene()
        let palette = Self.vivid(model?.palette ?? [])
        let beats = beatPosition()
        let blackout = UserDefaults.standard.bool(forKey: Self.blackoutKey)
        let master = Self.master
        // Colours ease over about half a second; levels follow at once, so
        // the beat lands.
        let ease = 1 - exp(-elapsed / 0.5)

        var lights: [UUID: DMX.Light] = [:]
        for (index, fixture) in fixtures.enumerated() {
            var target: DMX.Light
            if let testing {
                target = testing.only == nil || testing.only == fixture.id ? testing.light : .off
            } else {
                target = Self.light(scene, fixture: index, of: fixtures.count, palette: palette,
                                    beats: beats.flatMap { Self.pulses ? $0 : nil },
                                    time: now.timeIntervalSinceReferenceDate)
            }
            if blackout, testing == nil { target.level = 0 }
            target.level *= testing == nil ? master : 1
            let before = shown[fixture.id] ?? target
            let eased = testing == nil ? DMX.Light(red: before.red + (target.red - before.red) * ease,
                                                    green: before.green + (target.green - before.green) * ease,
                                                    blue: before.blue + (target.blue - before.blue) * ease,
                                                    level: target.level) : target
            lights[fixture.id] = eased
        }
        shown = lights

        port?.send(DMX.frame(fixtures) { lights[$0.id] ?? .off })
        if previewing > 0, now.timeIntervalSince(lastPreview) >= 0.1 {
            lastPreview = now
            preview = lights
        }
    }

    private func currentScene() -> Scene {
        guard let model else { return .standby }
        if model.intermission != nil {
            if case .listening = Applause.shared.phase {
                cheer += (Applause.shared.level - cheer) * 0.3
                return .intermission(cheer: cheer)
            }
            cheer = 0
            return .intermission(cheer: nil)
        }
        if model.fillerPlaying { return .houseMusic }
        if model.track != nil { return .song(playing: model.isPlaying) }
        return .standby
    }

    /// Beats since the grid's start, and how far into this one, while a song
    /// with a tempo plays; nil otherwise.
    private func beatPosition() -> Double? {
        guard let model, model.isPlaying, model.intermission == nil, !model.fillerPlaying,
              let tempo = model.publishedAnalysis?.tempo, tempo >= 40, tempo <= 250 else { return nil }
        return (model.lyricPosition - model.beatOffset) * tempo / 60
    }

    /// One fixture's light for a scene. `beats` (beats into the song) adds
    /// the pulse; fixtures share out the palette, which turns every four bars.
    nonisolated static func light(_ scene: Scene, fixture index: Int, of count: Int,
                                  palette: [DMX.Light], beats: Double?, time: Double) -> DMX.Light {
        let colours = palette.isEmpty ? house : palette
        func colour(_ shift: Int) -> DMX.Light { colours[((index + shift) % colours.count + colours.count) % colours.count] }

        switch scene {
        case .song(let playing):
            guard playing else { return colour(0).at(0.25) }
            guard let beats else { return colour(Int(time / 8)).at(0.4) }
            let into = beats - beats.rounded(.down)
            return colour(Int(beats / 16)).at(0.35 + 0.35 * exp(-4 * into))
        case .intermission(let cheer):
            if let cheer { return colour(0).at(0.3 + 0.7 * min(1, max(0, cheer))) }
            return DMX.Light(red: 1, green: 0.8, blue: 0.6, level: 0.85)
        case .houseMusic:
            return colour(Int(time / 20)).at(0.4 + 0.12 * sin(time * 2 * .pi / 6 + Double(index)))
        case .standby:
            let hue = (time / 40 + Double(index) / Double(max(1, count))).truncatingRemainder(dividingBy: 1)
            return hsv(hue, 0.85, 1).at(0.3)
        }
    }

    /// Studio One's own colours, for a song with no cover.
    nonisolated static let house: [DMX.Light] = [
        DMX.Light(red: 1, green: 0.3, blue: 0.75, level: 1),
        DMX.Light(red: 0.25, green: 0.8, blue: 1, level: 1),
        DMX.Light(red: 0.55, green: 0.35, blue: 1, level: 1),
    ]

    /// A cover's colours as light: full brightness and more saturated, since
    /// a fixture's dull brown is just dim orange. Near-greys become a warm
    /// white.
    nonisolated static func vivid(_ palette: [PaletteColor]) -> [DMX.Light] {
        palette.map { colour in
            let top = max(colour.red, colour.green, colour.blue)
            let bottom = min(colour.red, colour.green, colour.blue)
            guard top > 0.02, (top - bottom) / top > 0.15 else { return DMX.Light(red: 1, green: 0.8, blue: 0.6, level: 1) }
            let (hue, saturation, _) = hsvOf(colour.red, colour.green, colour.blue)
            return hsv(hue, min(1, saturation * 1.4), 1)
        }
    }

    nonisolated static func hsv(_ hue: Double, _ saturation: Double, _ value: Double) -> DMX.Light {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6, f = h - Double(Int(h))
        let p = value * (1 - saturation), q = value * (1 - saturation * f), t = value * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0:  (r, g, b) = (value, t, p)
        case 1:  (r, g, b) = (q, value, p)
        case 2:  (r, g, b) = (p, value, t)
        case 3:  (r, g, b) = (p, q, value)
        case 4:  (r, g, b) = (t, p, value)
        default: (r, g, b) = (value, p, q)
        }
        return DMX.Light(red: r, green: g, blue: b, level: 1)
    }

    nonisolated static func hsvOf(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let top = max(r, g, b), bottom = min(r, g, b), span = top - bottom
        guard top > 0, span > 0 else { return (0, 0, top) }
        var hue: Double
        if top == r { hue = (g - b) / span } else if top == g { hue = 2 + (b - r) / span } else { hue = 4 + (r - g) / span }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, span / top, top)
    }
}
