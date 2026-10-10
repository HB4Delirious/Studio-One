import Foundation

/// DMX512 for the room's lights, through a USB interface: each fixture's
/// channels laid out by address in a 512-channel frame, and the bytes the
/// interface wants for it.
enum DMX {
    static let universe = 512

    enum Interface: String, CaseIterable, Identifiable, Codable {
        /// ENTTEC DMX USB Pro and the many that speak its protocol (DMXking
        /// ultraDMX, Eurolite Pro…): frames go in packets and the interface
        /// keeps the line's timing.
        case enttecPro
        /// ENTTEC Open DMX USB and other plain FTDI cables: the Mac sends the
        /// break and the 250 kbaud data itself.
        case openDMX

        var id: String { rawValue }

        var title: String {
            switch self {
            case .enttecPro: return "DMX USB Pro"
            case .openDMX:   return "Open DMX"
            }
        }
    }

    /// What a fixture's channels are, in order from its address.
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case dimmer, rgb, rgbw, dimmerRGB, dimmerRGBW

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dimmer:     return "Dimmer"
            case .rgb:        return "RGB"
            case .rgbw:       return "RGBW"
            case .dimmerRGB:  return "Dimmer + RGB"
            case .dimmerRGBW: return "Dimmer + RGBW"
            }
        }

        var channels: Int {
            switch self {
            case .dimmer:     return 1
            case .rgb:        return 3
            case .rgbw:       return 4
            case .dimmerRGB:  return 4
            case .dimmerRGBW: return 5
            }
        }

        var hasColour: Bool { self != .dimmer }
    }

    struct Fixture: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        /// Its first channel, 1–512.
        var address: Int
        var kind: Kind

        var lastChannel: Int { address + kind.channels - 1 }
    }

    /// A colour, each part 0…1, and how bright, 0…1.
    struct Light: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var level: Double

        static let off = Light(red: 0, green: 0, blue: 0, level: 0)

        func at(_ level: Double) -> Light { Light(red: red, green: green, blue: blue, level: level) }
    }

    /// A fixture's channel values for a light. A fixture with a dimmer
    /// channel gets the colour at full and the level on the dimmer; one
    /// without has the level in its colour. A white channel takes the part
    /// the three colours share.
    static func channels(_ kind: Kind, _ light: Light) -> [UInt8] {
        let level = clamp(light.level)
        let r = clamp(light.red), g = clamp(light.green), b = clamp(light.blue)
        let white = min(r, g, b)
        switch kind {
        case .dimmer:     return [byte(level * max(r, g, b))]
        case .rgb:        return [r, g, b].map { byte($0 * level) }
        case .rgbw:       return [r - white, g - white, b - white, white].map { byte($0 * level) }
        case .dimmerRGB:  return [byte(level)] + [r, g, b].map(byte)
        case .dimmerRGBW: return [byte(level)] + [r - white, g - white, b - white, white].map(byte)
        }
    }

    /// The whole universe: each fixture's channels at its address. Channels
    /// past 512 are dropped; where fixtures overlap, the later one wins.
    static func frame(_ fixtures: [Fixture], light: (Fixture) -> Light) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: universe)
        for fixture in fixtures where fixture.address >= 1 {
            for (offset, value) in channels(fixture.kind, light(fixture)).enumerated() {
                let index = fixture.address - 1 + offset
                if index < universe { frame[index] = value }
            }
        }
        return frame
    }

    /// The DMX USB Pro's "Output Only Send DMX Packet" (label 6): start code
    /// 0, then the channels.
    static func enttecPacket(_ frame: [UInt8]) -> [UInt8] {
        let length = frame.count + 1
        return [0x7E, 6, UInt8(length & 0xFF), UInt8(length >> 8), 0x00] + frame + [0xE7]
    }

    /// Fixture → the name of an earlier one sharing a channel with it.
    static func overlaps(_ fixtures: [Fixture]) -> [UUID: String] {
        var found: [UUID: String] = [:]
        for (index, fixture) in fixtures.enumerated() {
            if let other = fixtures[..<index].first(where: {
                $0.address <= fixture.lastChannel && fixture.address <= $0.lastChannel
            }) {
                found[fixture.id] = other.name
            }
        }
        return found
    }

    /// The USB serial ports in /dev an interface could be.
    static func ports(among names: [String]) -> [String] {
        names.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.usbmodem") }
            .sorted()
            .map { "/dev/" + $0 }
    }

    static func availablePorts() -> [String] {
        ports(among: (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }
    private static func byte(_ value: Double) -> UInt8 { UInt8((clamp(value) * 255).rounded()) }
}

/// The interface's serial port, written from a thread of its own: DMX wants
/// a steady stream that the main thread's hiccups shouldn't break. The latest
/// frame goes out about thirty times a second until `close()`.
final class DMXPort: @unchecked Sendable {
    let path: String
    let interface: DMX.Interface

    private let fd: Int32
    private let lock = NSLock()
    private var frame = [UInt8](repeating: 0, count: DMX.universe)
    private var running = true
    private let finished = DispatchSemaphore(value: 0)
    private let onFailure: @Sendable (String) -> Void

    // <sys/ttycom.h> and <IOKit/serial/ioss.h>: function-like macros Swift
    // doesn't import.
    private static let exclusive: UInt = 0x2000_740D   // TIOCEXCL
    private static let breakOn: UInt = 0x2000_747B     // TIOCSBRK
    private static let breakOff: UInt = 0x2000_747A    // TIOCCBRK
    private static let setSpeed: UInt = 0x8008_5402    // IOSSIOSPEED

    struct OpenError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Opens the port for this interface, or throws why not. `onFailure` is
    /// called, off the main thread, if writing stops working (unplugged).
    init(path: String, interface: DMX.Interface, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.path = path
        self.interface = interface
        self.onFailure = onFailure

        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw OpenError(message: String(cString: strerror(errno))) }
        func fail(_ what: String) -> OpenError {
            let error = OpenError(message: "\(what): \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return error
        }
        guard ioctl(fd, Self.exclusive) == 0 else { throw fail("In use") }
        guard fcntl(fd, F_SETFL, 0) == 0 else { throw fail("Settings") }   // Writes block from here.

        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { throw fail("Settings") }
        cfmakeraw(&options)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        // DMX's two stop bits; the Pro ignores the line settings.
        if interface == .openDMX { options.c_cflag |= tcflag_t(CSTOPB) }
        cfsetspeed(&options, speed_t(B57600))
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw fail("Settings") }
        if interface == .openDMX {
            var speed = speed_t(250_000)
            guard withUnsafeMutablePointer(to: &speed, { ioctl(fd, Self.setSpeed, $0) }) == 0 else {
                throw fail("250 kbaud")
            }
        }
        self.fd = fd

        let thread = Thread { [self] in run() }
        thread.name = "DMX output"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func send(_ frame: [UInt8]) {
        lock.lock()
        self.frame = frame
        lock.unlock()
    }

    /// Stops the stream and closes the port, waiting briefly for the last
    /// frame so the port is free to open again at once.
    func close() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning { _ = finished.wait(timeout: .now() + 0.5) }
    }

    private func run() {
        let interval = 1.0 / 30
        var next = Date()
        var failure: String?
        while true {
            lock.lock()
            let going = running, data = frame
            lock.unlock()
            guard going else { break }

            switch interface {
            case .enttecPro:
                if !write(DMX.enttecPacket(data)) { failure = String(cString: strerror(errno)) }
            case .openDMX:
                // A break of at least 88 µs and a mark after it, then the
                // start code and the channels; drained so the next break
                // can't cut into them.
                _ = ioctl(fd, Self.breakOn)
                usleep(120)
                _ = ioctl(fd, Self.breakOff)
                usleep(20)
                if !write([0] + data) { failure = String(cString: strerror(errno)) } else { tcdrain(fd) }
            }
            if let failure {
                lock.lock()
                running = false
                lock.unlock()
                onFailure(failure)
                break
            }
            next += interval
            let wait = next.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) } else { next = Date() }
        }
        Darwin.close(fd)
        finished.signal()
    }

    private func write(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return false
            }
            sent += count
        }
        return true
    }
}
