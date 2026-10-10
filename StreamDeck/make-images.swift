import AppKit

// Draws every image the plug-in's manifest names, at 1× and 2×.
//
//   imgs/plugin          256 / 512   from Studio One's own app icon
//   imgs/category         28 / 56    white glyph, transparent
//   imgs/actions/<name>   20 / 40    white glyph, transparent (the actions list)
//   imgs/keys/<name>      72 / 144   dark tile with a glyph (a key's face)
//   imgs/dials/<name>     72 / 144   white glyph, transparent (touch-strip icon)
//
// Usage: swift make-images.swift <plugin folder> <app icon png>

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let appIcon = NSImage(contentsOfFile: CommandLine.arguments[2])

func png(_ side: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ path: String, _ base: Int, _ draw: @escaping (CGRect) -> Void) {
    let url = out.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! png(base, draw).write(to: URL(fileURLWithPath: url.path + ".png"))
    try! png(base * 2, draw).write(to: URL(fileURLWithPath: url.path + "@2x.png"))
}

/// An SF Symbol, filled with `color`, centred at `scale` of the rect.
func glyph(_ name: String, in rect: CGRect, scale: CGFloat, color: NSColor) {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: rect.width * scale, weight: .semibold)) else {
        FileHandle.standardError.write(Data("missing symbol \(name)\n".utf8))
        return
    }
    let size = symbol.size
    let fit = min(rect.width * scale / size.width, rect.height * scale / size.height)
    let drawn = CGSize(width: size.width * fit, height: size.height * fit)
    let target = CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                        width: drawn.width, height: drawn.height)
    // Tint: draw the symbol, then fill over it keeping only its pixels.
    let tinted = NSImage(size: drawn, flipped: false) { bounds in
        symbol.draw(in: bounds)
        color.set()
        bounds.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: target)
}

/// Studio One's colours: the dark stage and the aurora accent from its icon.
let backdropTop = NSColor(red: 0.16, green: 0.13, blue: 0.24, alpha: 1)
let backdropBottom = NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
let accent = NSColor(red: 0.98, green: 0.36, blue: 0.45, alpha: 1)

func keyTile(_ name: String, scale: CGFloat = 0.5, color: NSColor = .white, lift: CGFloat = 0) -> (CGRect) -> Void {
    { rect in
        NSGradient(starting: backdropTop, ending: backdropBottom)!.draw(in: rect, angle: -90)
        glyph(name, in: rect.offsetBy(dx: 0, dy: rect.height * lift), scale: scale, color: color)
    }
}

// Plug-in and category icons
write("imgs/plugin", 256) { rect in
    if let appIcon { appIcon.draw(in: rect) }
    else { NSGradient(starting: backdropTop, ending: backdropBottom)!.draw(in: rect, angle: -90) }
}
write("imgs/category", 28) { rect in glyph("music.mic", in: rect, scale: 0.8, color: .white) }

// Action list icons, key faces and dial icons
let keys: [(String, String)] = [
    ("playpause", "playpause.fill"), ("next", "forward.end.fill"), ("previous", "backward.end.fill"),
    ("nowplaying", "music.note"), ("keybpm", "music.note.list"), ("lyricsfull", "music.mic"),
    ("source", "arrow.triangle.2.circlepath"), ("reload", "arrow.clockwise"),
    ("fadeout", "speaker.wave.1.fill"),
]
let dials: [(String, String)] = [
    ("mixer", "slider.horizontal.3"), ("midi", "pianokeys"),
    ("key", "tuningfork"), ("tempo", "metronome.fill"), ("sync", "captions.bubble.fill"),
    ("volume", "speaker.wave.2.fill"), ("seek", "timeline.selection"), ("font", "textformat.size"),
]

for (name, symbol) in keys + dials.map({ ("dial-" + $0.0, $0.1) }) {
    write("imgs/actions/\(name)", 20) { rect in glyph(symbol, in: rect, scale: 0.9, color: .white) }
}

write("imgs/keys/play", 72, keyTile("play.fill", scale: 0.42, color: accent))
write("imgs/keys/pause", 72, keyTile("pause.fill", scale: 0.42, color: accent))
write("imgs/keys/next", 72, keyTile("forward.end.fill", scale: 0.42))
write("imgs/keys/previous", 72, keyTile("backward.end.fill", scale: 0.42))
write("imgs/keys/nowplaying", 72, keyTile("music.note", scale: 0.42))
write("imgs/keys/lyricsfull", 72, keyTile("music.mic", scale: 0.42))
write("imgs/keys/reload", 72, keyTile("arrow.clockwise", scale: 0.42))
write("imgs/keys/fadeout", 72, keyTile("speaker.wave.1.fill", scale: 0.42))
write("imgs/keys/mute", 72, keyTile("mic.slash.fill", scale: 0.28, color: accent, lift: 0.28))
write("imgs/actions/mute", 20) { rect in glyph("mic.slash.fill", in: rect, scale: 0.9, color: .white) }
write("imgs/actions/midi-key", 20) { rect in glyph("pianokeys", in: rect, scale: 0.9, color: .white) }
write("imgs/keys/midi", 72, keyTile("pianokeys", scale: 0.26, color: accent, lift: 0.28))
// Keys that carry text get a small glyph near the top, leaving room for it.
write("imgs/keys/keybpm", 72, keyTile("music.note.list", scale: 0.22, color: accent, lift: 0.3))
write("imgs/keys/source", 72, keyTile("arrow.triangle.2.circlepath", scale: 0.22, color: accent, lift: 0.3))

for (name, symbol) in dials {
    write("imgs/dials/\(name)", 72) { rect in glyph(symbol, in: rect, scale: 0.6, color: .white) }
}
print("images written to \(out.path)")
