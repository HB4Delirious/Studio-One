import SwiftUI

/// A dark room with a bright screen. Everything is tuned so the sung word is the
/// only genuinely saturated thing on screen — chrome stays near-monochrome.
enum Theme {
    static let backdrop = Color(red: 0.043, green: 0.039, blue: 0.078)   // #0B0A14
    static let panel = Color(red: 0.086, green: 0.082, blue: 0.137)      // #161523
    static let upcoming = Color(red: 0.42, green: 0.42, blue: 0.53)      // dim slate
    static let sung = Color(red: 1.0, green: 0.76, blue: 0.29)           // #FFC24B amber
    static let cue = Color(red: 0.37, green: 0.88, blue: 0.82)           // #5EE0D0 cyan
    static let hairline = Color.white.opacity(0.07)

    /// Third visualizer field colour. Only ever appears in the background —
    /// the sung word stays the one saturated thing in the foreground.
    static let violet = Color(red: 0.45, green: 0.30, blue: 0.95)

    /// Heavy and rounded: reads at a distance and doesn't look like body copy.
    static func lyric(_ size: CGFloat, active: Bool) -> Font {
        .system(size: size, weight: active ? .heavy : .semibold, design: .rounded)
    }

    static let timecode = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// Two colours for a placeholder tile, derived from a name so a playlist
    /// keeps the same look between launches and while its cover loads.
    static func tile(for name: String) -> [Color] {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360
        return [Color(hue: hue, saturation: 0.55, brightness: 0.62),
                Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                      saturation: 0.68, brightness: 0.38)]
    }
}
