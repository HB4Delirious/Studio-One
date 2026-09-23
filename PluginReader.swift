import AVFoundation
import AudioToolbox
import Foundation

/// What was read out of an installed pitch plug-in: which controller value
/// selects each root and each of Major and Minor, measured rather than assumed.
///
/// Built because the menus cannot be known from outside. Waves' manual never
/// lists its Scale menu, a saved project only shows the current position, and
/// a root menu may list C♯ and D♭ as two entries — at which point "twelve
/// equal steps" lands on the wrong key for most of them. The plug-in itself
/// knows, so it is asked.
struct PluginReading: Codable, Equatable {
    let pluginName: String
    let rootParameter: String
    let rootEntryCount: Int
    /// Controller value for each pitch class, 0 = C. All twelve present.
    let rootValues: [Int]
    let scaleParameter: String?
    let scaleEntryCount: Int
    let majorName: String?
    let minorName: String?
    let majorValue: Int?
    let minorValue: Int?
    let date: Date

    var canSendScale: Bool { majorValue != nil && minorValue != nil }

    static func key(for plugin: PitchPlugin) -> String { "pluginReading.\(plugin.rawValue)" }

    static func stored(for plugin: PitchPlugin) -> PluginReading? {
        guard let data = UserDefaults.standard.data(forKey: key(for: plugin)) else { return nil }
        return try? JSONDecoder().decode(PluginReading.self, from: data)
    }

    func store(for plugin: PitchPlugin) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(for: plugin))
        }
    }

    static func forget(for plugin: PitchPlugin) {
        UserDefaults.standard.removeObject(forKey: key(for: plugin))
    }
}

enum PluginReaderError: LocalizedError {
    case notInstalled(String)
    case couldNotLoad(String, String)
    case noRootParameter([String])
    case unlabeled(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            return "\(name) isn't installed on this Mac as an Audio Unit."
        case .couldNotLoad(let name, let why):
            return "\(name) wouldn't load outside Logic (\(why)). If it asks for a license, open it in Logic once, then try again."
        case .noRootParameter(let names):
            return "Couldn't find a key or root control among its \(names.count) parameters. The full list is in the diagnostics log."
        case .unlabeled(let name):
            return "\(name) doesn't label its key values, so they can't be read. The parameter list is in the diagnostics log."
        }
    }
}

/// Loads a plug-in out of process — never inside Studio One, so a plug-in that
/// crashes on load takes only its helper down — and reads its key and scale.
enum PluginReader {

    /// Where to find each plug-in. The component codes come from the karaoke
    /// Logic project, which records them for every plug-in it uses; the names
    /// are the fallback for anything whose codes aren't known.
    static func target(for plugin: PitchPlugin) -> (manufacturer: String?, subtype: String?, name: String)? {
        switch plugin {
        case .wavesTuneRealTime:    return ("ksWV", "LVLS", "Waves Tune Real-Time")
        case .original:             return ("UADx", "UI14", "Topline Vocal Suite")
        case .autoTuneAccess:       return (nil, nil, "Auto-Tune Access")
        case .metaTune, .logicPitchCorrection: return nil
        }
    }

    static func read(_ plugin: PitchPlugin) async throws -> PluginReading {
        guard let target = target(for: plugin) else {
            throw PluginReaderError.notInstalled(plugin.displayName)
        }
        let component = try find(target)
        let unit: AVAudioUnit
        do {
            unit = try await AVAudioUnit.instantiate(with: component.audioComponentDescription,
                                                     options: .loadOutOfProcess)
        } catch {
            throw PluginReaderError.couldNotLoad(component.name, error.localizedDescription)
        }
        let parameters = unit.auAudioUnit.parameterTree?.allParameters ?? []
        Diagnostics.log("plugin reader: \(component.manufacturerName) \(component.name), \(parameters.count) parameters")
        for parameter in parameters {
            Diagnostics.log("  param \(parameter.address) \"\(parameter.displayName)\" \(parameter.minValue)…\(parameter.maxValue) unit=\(parameter.unit.rawValue) strings=\(parameter.valueStrings?.count ?? 0)")
        }
        return try reading(from: parameters, pluginName: component.name)
    }

    static func find(_ target: (manufacturer: String?, subtype: String?, name: String)) throws -> AVAudioUnitComponent {
        let all = AVAudioUnitComponentManager.shared().components(passingTest: { _, _ in true })
        if let manufacturer = target.manufacturer, let subtype = target.subtype,
           let exact = all.first(where: {
               fourCC($0.audioComponentDescription.componentManufacturer) == manufacturer
                   && fourCC($0.audioComponentDescription.componentSubType) == subtype
           }) {
            return exact
        }
        let wanted = target.name.lowercased()
        if let named = all.first(where: { $0.name.lowercased().contains(wanted) }) { return named }
        throw PluginReaderError.notInstalled(target.name)
    }

    // MARK: - Reading

    /// Pure: takes parameters, returns the table. Separate from loading so it
    /// can be exercised against any Audio Unit, not only the four tuners.
    static func reading(from parameters: [AUParameter], pluginName: String) throws -> PluginReading {
        guard let root = parameters.first(where: { isRootName($0.displayName) }) else {
            throw PluginReaderError.noRootParameter(parameters.map(\.displayName))
        }
        let rootEntries = entries(of: root)
        var rootValues = [Int?](repeating: nil, count: 12)
        for entry in rootEntries {
            guard let pitchClass = pitchClass(of: entry.label), rootValues[pitchClass] == nil else { continue }
            rootValues[pitchClass] = controllerValue(for: entry, in: root)
        }
        guard rootValues.allSatisfy({ $0 != nil }) else { throw PluginReaderError.unlabeled(pluginName) }

        let scale = parameters.first(where: { isScaleName($0.displayName) && $0 !== root })
        let scaleEntries = scale.map(entries(of:)) ?? []
        let major = bestScaleEntry(scaleEntries, minor: false)
        let minor = bestScaleEntry(scaleEntries, minor: true)

        return PluginReading(
            pluginName: pluginName,
            rootParameter: root.displayName,
            rootEntryCount: rootEntries.count,
            rootValues: rootValues.map { $0! },
            scaleParameter: scale?.displayName,
            scaleEntryCount: scaleEntries.count,
            majorName: major?.label,
            minorName: minor?.label,
            majorValue: major.flatMap { entry in scale.flatMap { controllerValue(for: entry, in: $0) } },
            minorValue: minor.flatMap { entry in scale.flatMap { controllerValue(for: entry, in: $0) } },
            date: Date())
    }

    struct Entry: Equatable {
        let label: String
        /// Parameter values that display as this entry, half-open.
        let lower: Float
        let upper: Float
        /// Set for indexed parameters: the exact integer this entry is.
        let index: Float?
    }

    /// The menu, in order. Indexed parameters say so directly; anything else is
    /// swept across its range and cut wherever its displayed text changes —
    /// which is exactly how the plug-in will interpret whatever Logic sends.
    static func entries(of parameter: AUParameter) -> [Entry] {
        let low = parameter.minValue, high = parameter.maxValue
        if let strings = parameter.valueStrings, !strings.isEmpty {
            return strings.enumerated().map { offset, label in
                let value = low + Float(offset)
                return Entry(label: label, lower: value - 0.5, upper: value + 0.5, index: value)
            }
        }
        guard high > low else { return [] }
        let samples = 2_000
        var result: [Entry] = []
        var label: String?
        var start = low
        for step in 0...samples {
            let value = low + (high - low) * Float(step) / Float(samples)
            let text = parameter.string(fromValue: [value]).trimmingCharacters(in: .whitespaces)
            if text != label {
                if let label { result.append(Entry(label: label, lower: start, upper: value, index: nil)) }
                label = text
                start = value
            }
        }
        if let label { result.append(Entry(label: label, lower: start, upper: high + .ulpOfOne, index: nil)) }
        return result
    }

    /// The 0–127 value that lands inside `entry` once Logic scales it linearly
    /// onto the parameter's range.
    ///
    /// For an indexed parameter the target is the integer itself, approached
    /// from above: a value in [k, k + ½) reads as k whether the host rounds it
    /// or the plug-in truncates it. For a swept one, the middle of its run.
    static func controllerValue(for entry: Entry, in parameter: AUParameter) -> Int? {
        let low = parameter.minValue, span = parameter.maxValue - parameter.minValue
        guard span > 0 else { return nil }
        let (lower, upper, aim): (Float, Float, Float)
        if let index = entry.index {
            (lower, upper, aim) = (index, index + 0.5, index + 0.25)
        } else {
            (lower, upper, aim) = (entry.lower, entry.upper, (entry.lower + entry.upper) / 2)
        }
        let candidates = (0...127).filter { v in
            let x = low + span * Float(v) / 127
            return x >= lower && x < upper
        }
        return candidates.min { a, b in
            abs(low + span * Float(a) / 127 - aim) < abs(low + span * Float(b) / 127 - aim)
        }
    }

    // MARK: - Names

    static func isRootName(_ name: String) -> Bool {
        let n = name.lowercased()
        guard !n.contains("detect"), !n.contains("speed"), !n.contains("track") else { return false }
        return n == "key" || n == "root" || n.hasSuffix(" key") || n.hasSuffix(" root")
            || n.hasSuffix("_key") || n.contains("root note") || n == "tonic"
    }

    static func isScaleName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == "scale" || n.hasSuffix(" scale") || n.hasSuffix("_scale")
    }

    /// "C", "C#", "C♯", "Db", "D♭", "C#/Db", "C# Major" → pitch class. The
    /// first spelling wins, so a menu listing C♯ and D♭ separately maps both to
    /// 1 and the first of them is used.
    static func pitchClass(of label: String) -> Int? {
        let text = label.trimmingCharacters(in: .whitespaces)
        guard let head = text.first?.uppercased().first,
              let natural = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(head)] else { return nil }
        let rest = text.dropFirst()
        // A bare note name, or one followed by an accidental, separator or space.
        if let next = rest.first, next.isLetter, next != "b" { return nil }
        var value = natural
        if rest.hasPrefix("#") || rest.hasPrefix("♯") { value += 1 }
        else if rest.hasPrefix("b") || rest.hasPrefix("♭") { value -= 1 }
        return (value + 12) % 12
    }

    /// Plain Major or natural Minor, never Harmonic, Melodic, Pentatonic, Blues
    /// or a chord.
    static func bestScaleEntry(_ entries: [Entry], minor: Bool) -> Entry? {
        let excluded = ["harmonic", "melodic", "pentatonic", "blues", "chord", "7", "bebop", "hungarian", "neapolitan"]
        func score(_ label: String) -> Int {
            let l = label.lowercased().trimmingCharacters(in: .whitespaces)
            if excluded.contains(where: { l.contains($0) }) { return 0 }
            if minor {
                if l == "minor" || l == "natural minor" || l == "minor (natural)" { return 3 }
                if l == "aeolian" { return 2 }
                return l.contains("minor") ? 1 : 0
            } else {
                if l == "major" { return 3 }
                if l == "ionian" { return 2 }
                return l.contains("major") ? 1 : 0
            }
        }
        // The first of the best, so a menu that repeats a name uses its first.
        var best: (entry: Entry, score: Int)?
        for entry in entries {
            let s = score(entry.label)
            if s > 0, s > (best?.score ?? 0) { best = (entry, s) }
        }
        return best?.entry
    }

    static func fourCC(_ value: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }, encoding: .macOSRoman) ?? ""
    }
}
