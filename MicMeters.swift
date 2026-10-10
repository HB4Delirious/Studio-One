import SwiftUI

/// The mics' levels, from the meters Logic sends the plug-in display's two
/// Mackie units: which channel strip each mic is, and what that strip shows.
/// For the Controls window's meters, a warning when no mic has been heard
/// while lines are being sung, and on the lyrics screen, a duet part's label
/// glowing with its singer's mic.
enum MicMeters {
    static let enabledKey = "micMeters"
    static let stripsKey = "micMeterStrips"
    static let warnKey = "micSilenceWarning"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var warns: Bool { UserDefaults.standard.object(forKey: warnKey) as? Bool ?? true }

    /// Each mic's strip, 1–16 across the Mackie Control and its extender;
    /// mic 1 on strip 1 and so on until set.
    static func strip(for mic: Int) -> Int {
        let saved = UserDefaults.standard.array(forKey: stripsKey) as? [Int] ?? []
        return mic - 1 < saved.count ? saved[mic - 1] : mic
    }

    static func setStrip(_ strip: Int, for mic: Int) {
        var saved = UserDefaults.standard.array(forKey: stripsKey) as? [Int] ?? []
        while saved.count < mic { saved.append(saved.count + 1) }
        saved[mic - 1] = min(16, max(1, strip))
        UserDefaults.standard.set(saved, forKey: stripsKey)
    }

    static var micCount: Int { PitchPlugin.tunerCount }

    /// A mic's level, 0…1.
    @MainActor static func level(mic: Int) -> Double {
        let meters = PluginDisplay.shared.meters
        let index = strip(for: mic) - 1
        return meters.indices.contains(index) ? Double(meters[index]) / 12 : 0
    }

    /// A duet part's singer: part 1 on mic 1, part 2 on mic 2, both the louder.
    @MainActor static func level(for part: LyricPart?) -> Double {
        guard isEnabled, micCount >= 2, let part else { return 0 }
        switch part {
        case .first:  return level(mic: 1)
        case .second: return level(mic: 2)
        case .both:   return max(level(mic: 1), level(mic: 2))
        }
    }

    /// Logic is connected and sending what the meters need.
    @MainActor static var isLive: Bool {
        guard isEnabled else { return false }
        switch PluginDisplay.shared.phase {
        case .connected, .reading, .showing: return true
        default: return false
        }
    }

    /// Since any mic was last heard.
    @MainActor static var silentFor: TimeInterval {
        let heard = (1...micCount).map { PluginDisplay.shared.meterHeard[max(0, min(15, strip(for: $0) - 1))] }
        return Date().timeIntervalSince(heard.max() ?? .distantPast)
    }
}

/// The Controls window's mic meters, under the song's tools, with a warning
/// when lines are being sung and no mic has been heard for twenty seconds.
struct MicMeterStrip: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var display = PluginDisplay.shared
    @AppStorage(MicMeters.warnKey) private var warns = true

    var body: some View {
        if MicMeters.isLive {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("MICS").font(Theme.label).foregroundStyle(Theme.secondary)
                    ForEach(1...MicMeters.micCount, id: \.self) { mic in
                        HStack(spacing: 4) {
                            Text("\(mic)").font(Theme.timecode).foregroundStyle(Theme.secondary)
                            MeterBar(level: MicMeters.level(mic: mic))
                        }
                    }
                }
                if warns, singing, MicMeters.silentFor > 20 {
                    Label("No mic heard for 20 s while lines are being sung — is a mic off or muted?",
                          systemImage: "mic.slash.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Playing, with a sung line on screen — not an instrumental stretch.
    private var singing: Bool {
        guard model.isPlaying, model.lyricsState == .synced, model.intermission == nil, !model.fillerPlaying,
              let index = model.activeIndex(at: model.lyricPosition), model.lines.indices.contains(index) else { return false }
        return !model.lines[index].isBlank
    }
}

/// Twelve steps, green to amber to red, like a channel strip.
private struct MeterBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: geo.size.width * level)
                    }
            }
        }
        .frame(width: 54, height: 6)
        .animation(.linear(duration: 0.1), value: level)
    }
}

/// Settings › Plug-ins: which strip each mic is, and the warning.
struct MicMeterSettings: View {
    @AppStorage(MicMeters.enabledKey) private var enabled = true
    @AppStorage(MicMeters.warnKey) private var warns = true
    @AppStorage(PitchPlugin.tunerCountKey) private var tunerCount = 1
    @State private var strips: [Int] = (1...4).map { MicMeters.strip(for: $0) }

    var body: some View {
        SettingsSection("Mic meters", info: "Logic sends a Mackie Control a level for each channel strip it shows — eight on the Mackie Control, eight more on the extender, numbered 1 to 16 across both, in the order of Logic's mixer as the units show it. Set which strip each mic's channel is. If the meters stay still, bank the units in Logic so the mic channels are among the sixteen shown. The duet labels on the lyrics screen glow with part 1's mic (mic 1) and part 2's (mic 2).") {
            Toggle("Show the mics' levels from Logic", isOn: $enabled)
                .font(.system(size: 12, design: .rounded))
            if enabled {
                // Two to a row: mic 1 and 2, then 3 and 4.
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 1, through: mics, by: 2)), id: \.self) { first in
                        GridRow {
                            picker(first)
                            if first + 1 <= mics { picker(first + 1).padding(.leading, 18) }
                        }
                    }
                }
                Toggle("Warn when no mic is heard while lines are sung", isOn: $warns)
                    .font(.system(size: 12, design: .rounded))
            }
        }
    }

    private var mics: Int { min(4, max(1, tunerCount)) }

    private func picker(_ mic: Int) -> some View {
        LabelledRow("Mic \(mic):") {
            Picker("Mic \(mic) strip", selection: Binding(
                get: { strips[mic - 1] },
                set: { strips[mic - 1] = $0; MicMeters.setStrip($0, for: mic) })) {
                ForEach(1...16, id: \.self) { Text("Strip \($0)").tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }
}
