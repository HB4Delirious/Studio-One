import AppKit

// App icon: Apple Music and Spotify, folded together.
//
// Two of Spotify's arcs, and beneath them a third that doubles as the beam of
// Apple Music's note — the stems and heads hang from its ends. One shape
// reading as both marks rather than two marks side by side.
//
// The colour is the harder half. Spotify green and Apple Music red sit opposite
// each other on the wheel, so blending them directly runs through brown. Going
// the long way round instead — pink, magenta, violet, blue, teal, green — keeps
// every step saturated and ends on each brand's own colour.
//
// Three outputs:
//
//   icon-1024.png        light: gradient plate, white mark.
//   icon-1024-dark.png   dark: black plate, and the gradient moves into the
//                        mark. Same drawing, inverted relationship.
//   StudioOne.icon/      the Liquid Glass source (--glass), which needs the
//                        mark alone on transparency.

let side: CGFloat = 1024
let plateInset: CGFloat = 92          // the macOS icon grid
let glass = CommandLine.arguments.contains("--glass")

func hex(_ s: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255,
                   green: CGFloat((v >> 8) & 255) / 255,
                   blue: CGFloat(v & 255) / 255, alpha: 1)
}

func aurora() -> NSGradient {
    NSGradient(colorsAndLocations:
        (hex("FB5C74"), 0.00),   // Apple Music pink
        (hex("FA233B"), 0.12),   // Apple Music red
        (hex("E23B9E"), 0.31),
        (hex("8E4BE8"), 0.47),
        (hex("3D86D8"), 0.57),
        (hex("10BE93"), 0.72),
        (hex("1DB954"), 0.89),   // Spotify green
        (hex("0C8B3D"), 1.00))!
}

/// The mark. `true` means fill rather than stroke.
func marks() -> [(NSBezierPath, Bool)] {
    var out: [(NSBezierPath, Bool)] = []
    let cx: CGFloat = 512, cy: CGFloat = 360

    // The two outer arcs — the Spotify cue.
    for (radius, width) in [(CGFloat(366), CGFloat(58)), (282, 50)] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: radius,
                      startAngle: 42, endAngle: 138, clockwise: false)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        out.append((arc, false))
    }

    // The innermost arc is also the note's beam, so the stems hang from its ends.
    let beamRadius: CGFloat = 197, beamStart: CGFloat = 52
    let beam = NSBezierPath()
    beam.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: beamRadius,
                   startAngle: beamStart, endAngle: 128, clockwise: false)
    beam.lineWidth = 48
    beam.lineCapStyle = .round
    out.append((beam, false))

    let reach = beamRadius * cos(beamStart * .pi / 180)
    let beamY = cy + beamRadius * sin(beamStart * .pi / 180)

    // Uneven head heights, the way a beamed pair is actually engraved.
    for (stemX, headY) in [(cx + reach, CGFloat(352)), (cx - reach, CGFloat(310))] {
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: stemX, y: beamY))
        stem.line(to: NSPoint(x: stemX, y: headY))
        stem.lineWidth = 38
        stem.lineCapStyle = .round
        out.append((stem, false))

        var place = AffineTransform(translationByX: stemX - 44, byY: headY - 10)
        place.rotate(byRadians: -0.30)
        let head = NSBezierPath(ovalIn: NSRect(x: -72, y: -55, width: 144, height: 110))
        head.transform(using: place)
        out.append((head, true))
    }
    return out
}

func canvas(_ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    body(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func plateRect() -> NSRect {
    NSRect(x: plateInset, y: plateInset,
           width: side - plateInset * 2, height: side - plateInset * 2)
}

/// Outline bounds with stroke width included. `NSBezierPath.bounds` gives the
/// centreline only, which would clip the sweep by half a stroke all round.
func markBounds(_ paths: [(NSBezierPath, Bool)]) -> CGRect {
    var rect = CGRect.null
    for (path, fill) in paths {
        let outline = fill ? path.cgPath
                           : path.cgPath.copy(strokingWithWidth: path.lineWidth,
                                              lineCap: .round, lineJoin: .round,
                                              miterLimit: 10)
        rect = rect.union(outline.boundingBox)
    }
    return rect
}

/// Paint the mark, either flat in one colour or filled with the gradient.
func paintMarks(_ ctx: CGContext, gradient: Bool) {
    let paths = marks()
    guard gradient else {
        for (path, fill) in paths {
            if fill { path.fill() } else { path.stroke() }
        }
        return
    }
    for (path, fill) in paths {
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        if !fill {
            ctx.setLineWidth(path.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath()
        }
        ctx.clip()
        // Across the mark's own bounds, not the plate's: the mark never reaches
        // the plate corners, so plate-sized sampling gave it only the middle of
        // the ramp — pink to teal, with the red and green ends missing. -30°
        // rather than the plate's -45° for the same reason: the mark is wider
        // than it is tall, so a shallower sweep runs the full ramp through it.
        aurora().draw(in: markBounds(paths), angle: -30)
        ctx.restoreGState()
    }
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// --- Light: gradient plate, white mark ---------------------------------------
write(canvas { ctx in
    ctx.saveGState()
    NSBezierPath(roundedRect: plateRect(), xRadius: 185, yRadius: 185).addClip()
    aurora().draw(in: plateRect(), angle: -45)
    ctx.restoreGState()
    NSColor.white.setStroke()
    NSColor.white.setFill()
    paintMarks(ctx, gradient: false)
}, to: "Icon/icon-1024.png")

// --- Dark: black plate, gradient mark ----------------------------------------
// Not flat black. A near-black plate with a little vertical lift keeps the
// rounded corners readable against a dark Dock, which pure #000 loses.
write(canvas { ctx in
    ctx.saveGState()
    NSBezierPath(roundedRect: plateRect(), xRadius: 185, yRadius: 185).addClip()
    NSGradient(colors: [hex("16141C"), hex("000000")])!.draw(in: plateRect(), angle: -90)
    ctx.restoreGState()
    paintMarks(ctx, gradient: true)
}, to: "Icon/icon-1024-dark.png")

// --- Liquid Glass layer: the mark alone, carrying the gradient ----------------
guard glass else { exit(0) }

let layer = canvas { ctx in paintMarks(ctx, gradient: true) }
try? FileManager.default.createDirectory(atPath: "Icon/StudioOne.icon/Assets",
                                         withIntermediateDirectories: true)
write(layer, to: "Icon/StudioOne.icon/Assets/glyph.png")
