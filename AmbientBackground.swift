import SwiftUI

/// Scattered particles behind the lyrics.
///
/// Driven by the lyric clock, not by audio — Apple Events never expose samples,
/// so there is no spectrum to analyse. Each particle is born on a beat somewhere
/// on the frame, grows, and fades out again, so the field is never the same twice
/// and nothing anchors it to the centre. When there is no beat to drive it, it
/// fades to an empty backdrop rather than idling. Kept dim on purpose: the lit
/// word should stay the brightest thing on screen.
struct AmbientBackground: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum

    var body: some View {
        // Capped at 30fps regardless of the lyric setting. These are soft,
        // slow-moving shapes over the whole window — the most fill-rate-hungry
        // thing on screen — and redrawing them at 120 buys nothing the eye can
        // see. The lyrics and the sweep still run at the full rate.
        TimelineView(.animation(minimumInterval: max(1.0 / 30.0, FrameRate.interval(for: targetFPS)),
                                paused: !model.isPlaying)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let position = model.lyricPosition
            let index = model.activeIndex(at: position)
            let line = index.flatMap { model.lines.indices.contains($0) ? model.lines[$0] : nil }

            // Take the cover's colours when we have them, the house palette when
            // we don't — a track with no artwork shouldn't lose its background.
            let colours: [Color] = model.palette.isEmpty
                ? [Theme.sung, Theme.cue, Theme.violet]
                : model.palette.map(\.color)

            let tempo = model.publishedAnalysis?.tempo
            let offset = model.beatOffset
            let hasBeat = (tempo.map { $0 >= 40 && $0 <= 250 }) ?? false
            let pulse = Self.pulse(at: position, line: line, bpm: tempo, offset: offset)

            // Particles are born on beats. With a tempo that's the real grid;
            // without one there is nothing to be on time with, so they ride the
            // wall clock and are gated by `energy` instead.
            let beats = hasBeat
                ? (position - offset) * tempo! / 60
                : now * 2

            // Nothing to show when nothing is driving it. With a tempo the field
            // runs continuously; without one it only appears on vocal onsets and
            // fades away between them. Stopped playback empties it entirely.
            let energy = !model.isPlaying ? 0 : (hasBeat ? 1 : pulse)

            Canvas(rendersAsynchronously: true) { context, size in
                Self.render(into: &context,
                            size: size,
                            time: now,
                            pulse: pulse,
                            // Faster songs spin faster, so the whole field
                            // reads as belonging to the track's energy.
                            rate: Self.driftRate(for: tempo),
                            beats: beats,
                            energy: energy,
                            colours: colours)
            }
            // Softened, so the shapes read as light rather than as wireframes.
            // opaque: true so the blur can't pull transparency in from the edges.
            .blur(radius: 5, opaque: true)
            .animation(.easeInOut(duration: 1.2), value: model.palette)
        }
    }

    /// A pulse per beat when the tempo is known, falling back to word onsets.
    ///
    /// The grid's phase is estimated once per track from where all the lyric
    /// lines fall (see `LRCParser.beatOffset`), so it stays continuous instead
    /// of resetting at every line.
    private static func pulse(at position: Double, line: LyricLine?,
                              bpm: Double?, offset: Double) -> Double {
        if let bpm, bpm >= 40, bpm <= 250 {
            let beat = 60.0 / bpm
            // One continuous grid for the whole song. Anchoring to the current
            // line meant the phase reset on every line, and lyric lines often
            // begin off the beat — which is precisely what read as offbeat.
            var phase = (position - offset).truncatingRemainder(dividingBy: beat)
            if phase < 0 { phase += beat }
            return exp(-3.4 * phase / beat)     // decays across one beat
        }

        // No tempo for this track: pulse on the vocal instead.
        guard let line else { return 0 }
        var onset = line.time
        if let state = line.wordState(at: position), line.words.indices.contains(state.index) {
            onset = line.words[state.index].time
        }
        let since = position - onset
        guard since >= 0, since < 2 else { return 0 }
        return exp(-4.5 * since)
    }

    /// 1.0 at 120 BPM, scaled gently either side so the motion tracks the song's
    /// pace without becoming frantic at high tempos.
    private static func driftRate(for bpm: Double?) -> Double {
        guard let bpm, bpm >= 40, bpm <= 250 else { return 1 }
        return 0.6 + 0.4 * (bpm / 120)
    }

    /// Particles are laid out one per cell of a coarse grid, jittered well past
    /// the cell edges. Purely random placement clumps — half the frame ends up
    /// crowded and the other half empty — and that reads as a bug rather than as
    /// chance. This keeps the coverage even while every position still looks
    /// arbitrary.
    private static let gridX = 6
    private static let gridY = 4
    private static let particleCount = gridX * gridY

    private static func render(into context: inout GraphicsContext,
                               size: CGSize, time: Double, pulse: Double,
                               rate: Double, beats: Double, energy: Double,
                               colours: [Color]) {
        let w = size.width, h = size.height
        guard w > 1, h > 1, !colours.isEmpty else { return }

        // Opaque base, so the blur applied to this canvas has no transparent
        // edges to smear inward.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.backdrop))
        guard energy > 0.01 else { return }

        let unit = min(w, h)
        let cellW = w / Double(gridX), cellH = h / Double(gridY)

        // Colours advance a step on every beat, so the field shifts hue in time
        // with the music rather than sitting on one palette entry.
        let beatIndex = Int(max(0, beats))

        context.blendMode = .plusLighter

        for slot in 0..<particleCount {
            let s = Double(slot)

            // Each slot runs its own cycle, a whole number of beats long and
            // staggered, so births land on the grid rather than all at once.
            let life = 2 + floor(hash(s * 1.7) * 4)         // 2–5 beats
            let stagger = floor(hash(s * 4.3) * life)
            let generation = floor((beats + stagger) / life)
            let age = (beats + stagger) - generation * life
            let u = age / life

            // Sharp attack on the beat it is born, long tail after — a hit
            // rather than a swell.
            let envelope = u < 0.14 ? u / 0.14 : pow(max(0, 1 - (u - 0.14) / 0.86), 1.7)
            guard envelope > 0.01 else { continue }

            // A fifth of the cycles are skipped outright, so the density rises
            // and falls instead of holding steady.
            guard hash(s * 3.31 + generation * 6.13) >= 0.22 else { continue }

            // Everything about a particle is derived from its slot and its
            // generation, so the canvas stays stateless and each rebirth is a
            // genuinely new shape in a new place.
            let r1 = hash(s * 9.13 + generation * 3.77)
            let r2 = hash(s * 5.21 + generation * 7.31)
            let r3 = hash(s * 2.77 + generation * 1.93)
            let r4 = hash(s * 6.49 + generation * 5.11)
            let r5 = hash(s * 8.07 + generation * 2.41)

            let cx = Double(slot % gridX), cy = Double(slot / gridX)
            let centre = CGPoint(
                x: (cx - 0.15 + r1 * 1.3) * cellW + (r3 - 0.5) * unit * 0.12 * u,
                y: (cy - 0.15 + r2 * 1.3) * cellH + (r4 - 0.5) * unit * 0.12 * u)

            // Expanding as it ages is what makes it read as struck rather than
            // as placed.
            let radius = unit * (0.06 + 0.15 * r5) * (0.40 + 0.95 * u) * (1 + 0.14 * pulse)
            let alpha = envelope * energy * (0.62 + 0.50 * pulse)
            let colour = colours[(slot + beatIndex) % colours.count]

            context.fill(
                Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [colour.opacity(alpha * 0.50), .clear]),
                    center: centre, startRadius: 0, endRadius: radius))

            particle(Int(r4 * 4) % 4, into: &context, at: centre, radius: radius,
                     spin: time * (0.2 + 0.5 * r3) * rate * (r1 < 0.5 ? -1 : 1),
                     colour: colour, alpha: alpha, seed: r2)
        }

        // The lyrics sit across the middle, so that band is pulled back down.
        // A full-height gradient rather than a rectangle: any edge would show as
        // a hard line now that the field around it can be near-black. Measured:
        // this keeps white text above 5:1 there in the worst case.
        context.blendMode = .normal
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [.clear, Theme.backdrop.opacity(0.45), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
    }

    /// One particle: a ring cluster, a polygon, a spiral or a burst.
    private static func particle(_ kind: Int, into context: inout GraphicsContext,
                                 at centre: CGPoint, radius: Double, spin: Double,
                                 colour: Color, alpha: Double, seed: Double) {
        switch kind {
        case 1:
            // Polygon, 3 to 8 sides, turning.
            let sides = 3 + Int(seed * 6)
            var path = Path()
            for k in 0...sides {
                let a = Double(k) / Double(sides) * 2 * .pi + spin
                let point = CGPoint(x: centre.x + cos(a) * radius,
                                    y: centre.y + sin(a) * radius)
                if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(colour.opacity(alpha)),
                           style: StrokeStyle(lineWidth: radius * 0.13, lineJoin: .round))

        case 2:
            // Spiral winding out from the middle.
            var path = Path()
            var t = 0.06
            var first = true
            while t <= 1 {
                let a = t * 9 + spin
                let point = CGPoint(x: centre.x + cos(a) * radius * t,
                                    y: centre.y + sin(a) * radius * t)
                if first { path.move(to: point); first = false } else { path.addLine(to: point) }
                t += 0.03
            }
            context.stroke(path, with: .color(colour.opacity(alpha)),
                           style: StrokeStyle(lineWidth: radius * 0.12, lineCap: .round))

        case 3:
            // Burst of thin petals. Kept narrow — filled shapes saturate
            // immediately under additive blending.
            let petals = 5 + Int(seed * 4)
            for i in 0..<petals {
                context.drawLayer { layer in
                    layer.translateBy(x: centre.x, y: centre.y)
                    layer.rotate(by: .radians(Double(i) / Double(petals) * 2 * .pi + spin))
                    layer.fill(
                        Path(ellipseIn: CGRect(x: -radius * 0.07, y: 0,
                                               width: radius * 0.14, height: radius)),
                        with: .color(colour.opacity(alpha * 0.8)))
                }
            }

        default:
            // Concentric rings.
            for i in 1...3 {
                let r = radius * Double(i) / 3
                context.stroke(
                    Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                           width: r * 2, height: r * 2)),
                    with: .color(colour.opacity(alpha * (1 - Double(i) * 0.18))),
                    lineWidth: radius * 0.11)
            }
        }
    }

    private static func hash(_ x: Double) -> Double {
        let v = sin(x) * 43758.5453
        return v - floor(v)
    }
}
