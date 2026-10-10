import SwiftUI

/// A dark room with a bright screen. Everything is tuned so the sung word is the
/// only genuinely saturated thing on screen — chrome stays near-monochrome.
enum Theme {
    static let backdrop = Color(red: 0.043, green: 0.039, blue: 0.078)   // #0B0A14
    static let panel = Color(red: 0.086, green: 0.082, blue: 0.137)      // #161523
    static let upcoming = Color(red: 0.42, green: 0.42, blue: 0.53)      // dim slate
    /// The sung word (#FFC24B amber) and the cue (#5EE0D0 cyan), unless the
    /// venue's theme says otherwise (see `VenueTheme`).
    static var sung: Color { VenueLook.current.sung }
    static var cue: Color { VenueLook.current.cue }
    /// The typeface on the room's screens, from the venue's theme.
    static var stageDesign: Font.Design { VenueLook.current.design }
    static let hairline = Color.white.opacity(0.07)
    /// Secondary text in the window's chrome. Brighter than `upcoming`, which
    /// is tuned for lyrics on the dark stage: it reads on glass over any cover.
    static let secondary = Color.white.opacity(0.62)

    /// A duet's parts as they're sung: the first singer amber like any lead,
    /// the second cyan, both together pink.
    static func part(_ part: LyricPart?) -> Color {
        switch part {
        case .second: return cue
        case .both:   return Color(red: 0.91, green: 0.22, blue: 0.56)   // #E8388F
        default:      return sung
        }
    }

    /// Third visualizer field colour. Only ever appears in the background —
    /// the sung word stays the one saturated thing in the foreground.
    static let violet = Color(red: 0.45, green: 0.30, blue: 0.95)

    /// Heavy and rounded: reads at a distance and doesn't look like body copy.
    static func lyric(_ size: CGFloat, active: Bool) -> Font {
        .system(size: size, weight: active ? .heavy : .semibold, design: stageDesign)
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
