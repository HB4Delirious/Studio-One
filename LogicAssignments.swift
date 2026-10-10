import Foundation

/// Logic's controller assignments, read from the file `LogicBackup` copies —
/// enough to find one that swallows Studio One's key changes.
///
/// Learn Mode records whatever arrives in one burst as a single control. If a
/// song's key goes out while it's on, Logic learns all twelve switch messages
/// as one assignment, bound to whatever was touched last, and from then on
/// takes that key's messages for it: MetaTune never sees them. On one rig,
/// "Send Mute 1 → TopLine", learned during an A♯ minor song, held every
/// C♯ major and A♯ minor song.
enum LogicAssignments {

    struct Swallower: Equatable {
        let label: String
        /// The key the burst was learned from, when it holds all twelve
        /// MetaTune switches: "C♯ major / A♯ minor".
        let key: String?

        /// One line for Settings and the log.
        var warning: String {
            let cause = key.map { "a whole key change (\($0)), so Logic takes those songs' messages for it and the tuners don't change" }
                ?? "several of Studio One's messages at once, so Logic takes them for it and the tuners miss them"
            return "Logic's “\(label)” was learned from \(cause). Delete it in Controller Assignments (⌥⇧K), Expert View."
        }
    }

    /// Assignments learned from a burst of Studio One's tuner messages. Empty
    /// when there are none or the file can't be read. Logic writes the file as
    /// it quits, so this is as of then.
    static func swallowers(in url: URL = LogicBackup.source) -> [Swallower] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return records(in: [UInt8](data)).compactMap(swallower)
    }

    // MARK: - The file

    struct Record: Equatable {
        /// The Value Change: the message or messages that trigger it, with
        /// placeholders (Lo7, Hi7 …) as bytes of 0x80 and up.
        let template: [UInt8]
        let label: String
    }

    /// Each assignment is a chunk tagged "RDAF" with its length after it
    /// (little-endian). A header of about 48 bytes is followed by tagged
    /// fields: 0x01 and a length for the Value Change, then 0x03 and a length
    /// for the label.
    static func records(in bytes: [UInt8]) -> [Record] {
        chunks(in: bytes).compactMap(record)
    }

    /// Every "RDAF" chunk, tag and length included.
    static func chunks(in bytes: [UInt8]) -> [[UInt8]] {
        let tag: [UInt8] = Array("RDAF".utf8)
        var result: [[UInt8]] = []
        var index = 0
        while index + 8 <= bytes.count {
            guard Array(bytes[index..<index + 4]) == tag else { index += 1; continue }
            let length = bytes[index + 4..<index + 8].reversed().reduce(0) { $0 << 8 | Int($1) }
            result.append(Array(bytes[index..<min(bytes.count, index + 8 + length)]))
            index += 8 + max(length, 0)
        }
        return result
    }

    private static func record(in body: [UInt8]) -> Record? {
        for start in 48..<min(body.count, 72) where body[start] == 0x01 {
            let count = Int(body[start + 1])
            let labelAt = start + 2 + count
            guard count > 0, labelAt + 1 < body.count, body[start + 2] >= 0x80,
                  body[labelAt] == 0x03 else { continue }
            let labelEnd = min(body.count, labelAt + 2 + Int(body[labelAt + 1]))
            let label = String(decoding: body[(labelAt + 2)..<labelEnd].prefix { $0 != 0 }, as: UTF8.self)
            return Record(template: Array(body[(start + 2)..<labelAt]), label: label)
        }
        return nil
    }

    // MARK: - Control surfaces' ports

    /// A control surface on the port that carries Studio One's key and
    /// tempo: Logic hands those messages to the surface instead of to the
    /// assignments, so the tuners and the tempo stop following the songs.
    struct WrongPort: Equatable {
        /// Logic's model name: "Mackie Control", "Mackie Control Extender".
        let surface: String
        let port: String

        private var right: String {
            surface.localizedCaseInsensitiveContains("extender") ? "Studio One Display 2" : "Studio One Display"
        }

        /// Two lines, for the Controls window.
        var banner: String {
            "Logic's \(surface) is on the “\(port)” port, so Logic gives it the key and tempo instead of your assignments. In Control Surfaces › Setup…, set it to “\(right)”."
        }

        var warning: String {
            "Logic's \(surface) is on the “\(port)” port, which carries Studio One's key and tempo — Logic gives them to the surface instead of your assignments, so the tuners and tempo don't follow the songs. In Logic Pro › Control Surfaces › Setup…, set its input and output to “\(right)” (or the Studio One Check ports, for the key check's surface)."
        }
    }

    /// Control surfaces on "Studio One" itself. Empty when there are none or
    /// the file can't be read; as Logic last saved, when it quit.
    static func wrongPorts(in url: URL = LogicBackup.source) -> [WrongPort] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return surfacePorts(in: [UInt8](data))
            .filter { $0.port == "Studio One" }
            .map { WrongPort(surface: $0.surface, port: $0.port) }
    }

    /// Each control surface's input. A surface's assignments follow its own
    /// chunk — the one naming it, "Control Surface: Mackie Control" — up to
    /// the next surface's, and carry at byte 23 their input, counted from 1
    /// in Logic's list of inputs; the most common one is the surface's.
    static func surfacePorts(in bytes: [UInt8]) -> [(surface: String, port: String)] {
        let inputs = inputPorts(in: bytes)
        let marker = Array("Control Surface: ".utf8)
        var result: [(surface: String, port: String)] = []
        var surface: String?
        var counts: [Int: Int] = [:]
        func close() {
            if let surface, let (port, _) = counts.max(by: { $0.value < $1.value }), inputs.indices.contains(port - 1) {
                result.append((surface, inputs[port - 1]))
            }
            counts = [:]
        }
        for chunk in chunks(in: bytes) {
            if let at = chunk.firstRange(of: marker) {
                close()
                surface = String(decoding: chunk[at.upperBound...].prefix { $0 >= 0x20 }, as: UTF8.self)
            } else if surface != nil, chunk.count > 23, chunk[23] > 0 {
                counts[Int(chunk[23]), default: 0] += 1
            }
        }
        close()
        return result
    }

    /// Logic's MIDI inputs, in its order: the second " PMC" table (outputs
    /// first), the tag and a little-endian length, then 100 bytes an input —
    /// an ID, the name in 64 bytes, a short name in 32.
    static func inputPorts(in bytes: [UInt8]) -> [String] {
        let tag = Array(" PMC".utf8)
        var tables: [[String]] = []
        var index = 0
        while index + 8 <= bytes.count, tables.count < 2 {
            guard Array(bytes[index..<index + 4]) == tag else { index += 1; continue }
            let length = bytes[index + 4..<index + 8].reversed().reduce(0) { $0 << 8 | Int($1) }
            var names: [String] = []
            var entry = index + 8
            while entry + 100 <= min(bytes.count, index + 8 + length) {
                names.append(String(decoding: bytes[(entry + 4)..<(entry + 68)].prefix { $0 != 0 }, as: UTF8.self))
                entry += 100
            }
            tables.append(names)
            index += 8 + max(length, 0)
        }
        return tables.count == 2 ? tables[1] : []
    }

    // MARK: - Reading a template

    struct Message: Equatable {
        let status: UInt8
        let data: [UInt8]
    }

    static func messages(in template: [UInt8]) -> [Message] {
        var result: [Message] = []
        var index = 0
        while index < template.count {
            let status = template[index]
            // Program change and channel pressure carry one data byte; the rest two.
            let count = (0xC0...0xDF).contains(status) ? 1 : 2
            guard status >= 0x80, status < 0xF0, index + count < template.count else { break }
            result.append(Message(status: status, data: Array(template[(index + 1)...(index + count)])))
            index += 1 + count
        }
        return result
    }

    /// Studio One's tuner controllers — key, scale, the twelve switches and
    /// bypass, Mackie-safe numbers included — on the mic channels.
    private static let tunerControllers: Set<UInt8> = Set([20, 21, 85, 86] + Array(102...114))

    /// Two or more of Studio One's tuner messages at fixed values in one
    /// template: a burst Logic learned whole. A real controller is one
    /// message, or a pair with placeholders.
    static func swallower(_ record: Record) -> Swallower? {
        let fixed = messages(in: record.template).filter { message in
            (0xB0...0xB3).contains(message.status) && tunerControllers.contains(message.data[0])
                && message.data[1] < 0x80
        }
        guard fixed.count >= 2 else { return nil }
        return Swallower(label: record.label, key: key(from: fixed))
    }

    /// The key whose switches these are, when all twelve are there.
    private static func key(from messages: [Message]) -> String? {
        var on: Set<Int> = []
        var seen: Set<Int> = []
        for message in messages where (102...113).contains(message.data[0]) {
            let pitchClass = Int(message.data[0]) - 102
            guard seen.insert(pitchClass).inserted else { continue }
            if (message.data[1] >= 64) != PitchPlugin.invertsNotes { on.insert(pitchClass) }
        }
        guard seen.count == 12,
              let root = (0..<12).first(where: { PitchPlugin.notes(root: $0, minor: false) == on }) else { return nil }
        return "\(PitchPlugin.noteNames[root]) major / \(PitchPlugin.noteNames[(root + 9) % 12]) minor"
    }
}
