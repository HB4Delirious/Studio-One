import AppKit
import SwiftUI

/// A venue's look on the room's screens — the lyrics, the standby screen and
/// the break: its name and message, its logo, the colours the words light up
/// in, their typeface, and the background. Kept as themes, one per venue, and
/// switched in Settings › Venue.
struct VenueTheme: Codable, Identifiable, Hashable {
    enum Typeface: String, Codable, CaseIterable, Identifiable {
        case rounded, classic, serif, mono
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rounded: return "Rounded"
            case .classic: return "Classic"
            case .serif:   return "Serif"
            case .mono:    return "Mono"
            }
        }
        var design: Font.Design {
            switch self {
            case .rounded: return .rounded
            case .classic: return .default
            case .serif:   return .serif
            case .mono:    return .monospaced
            }
        }
    }

    var id = UUID()
    var name: String
    /// Shown on the standby screen in place of "Studio One".
    var venueName = ""
    /// A line for the room on the standby and break screens: "Tuesdays 8 pm".
    var message = ""
    /// A file in the themes folder; nil shows Studio One's own icon.
    var logoFile: String?
    /// The sung word, and duets' second part, as sRGB hex.
    var sungHex = "FFC24B"
    var cueHex = "5EE0D0"
    var typeface = Typeface.rounded
    /// Nil keeps the song cover's colours behind the lyrics.
    var backgroundHex: String?

    static let standard = VenueTheme(name: "Studio One")
}

/// The current theme's colours and typeface, readable from any drawing code
/// without reaching into the store — set by it whenever the theme changes.
struct VenueLook {
    var sung: Color
    var cue: Color
    var design: Font.Design
    var background: Color?

    nonisolated(unsafe) static var current = VenueLook(theme: .standard)

    init(theme: VenueTheme) {
        sung = Color(hex: theme.sungHex) ?? Color(red: 1.0, green: 0.76, blue: 0.29)
        cue = Color(hex: theme.cueHex) ?? Color(red: 0.37, green: 0.88, blue: 0.82)
        design = theme.typeface.design
        background = theme.backgroundHex.flatMap(Color.init(hex:))
    }
}

/// The venues' themes, kept in Application Support with their logos.
@MainActor
final class VenueThemes: ObservableObject {
    static let shared = VenueThemes()

    @Published private(set) var themes: [VenueTheme] = []
    @Published private(set) var currentID: UUID?
    /// The current logo, loaded once per change rather than per frame.
    @Published private(set) var logo: NSImage?

    var current: VenueTheme { themes.first { $0.id == currentID } ?? .standard }

    private let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio One/Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private var file: URL { folder.appendingPathComponent("themes.json") }

    private struct Saved: Codable {
        var themes: [VenueTheme]
        var currentID: UUID?
    }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           !saved.themes.isEmpty {
            themes = saved.themes
            currentID = saved.currentID ?? saved.themes.first?.id
        } else {
            themes = [.standard]
            currentID = VenueTheme.standard.id
        }
        applied()
    }

    func use(_ id: UUID) {
        currentID = id
        saved()
    }

    /// Changes to a theme, from Settings.
    func update(_ theme: VenueTheme) {
        guard let index = themes.firstIndex(where: { $0.id == theme.id }) else { return }
        themes[index] = theme
        saved()
    }

    /// A new theme, starting from the current one, and switched to.
    func add() {
        var theme = current
        theme.id = UUID()
        theme.name = "New venue"
        if let logo = theme.logoFile { theme.logoFile = copyLogo(from: folder.appendingPathComponent(logo)) }
        themes.append(theme)
        currentID = theme.id
        saved()
    }

    func remove(_ id: UUID) {
        guard themes.count > 1, let index = themes.firstIndex(where: { $0.id == id }) else { return }
        if let logo = themes[index].logoFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(logo)) }
        themes.remove(at: index)
        if currentID == id { currentID = themes.first?.id }
        saved()
    }

    /// A logo for the current theme, copied in so the original can move.
    func setLogo(from url: URL?) {
        var theme = current
        if let old = theme.logoFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        theme.logoFile = url.flatMap(copyLogo(from:))
        update(theme)
    }

    private func copyLogo(from url: URL) -> String? {
        guard NSImage(contentsOf: url) != nil else { return nil }
        let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))) != nil else { return nil }
        return name
    }

    private func saved() {
        if let data = try? JSONEncoder().encode(Saved(themes: themes, currentID: currentID)) {
            try? data.write(to: file, options: .atomic)
        }
        applied()
    }

    private func applied() {
        let theme = current
        VenueLook.current = VenueLook(theme: theme)
        logo = theme.logoFile.flatMap { NSImage(contentsOf: folder.appendingPathComponent($0)) }
    }
}

extension Color {
    /// "FFC24B", with or without a leading #.
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// As sRGB hex, for saving a picked colour.
    var hex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}
