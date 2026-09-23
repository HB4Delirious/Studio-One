import SwiftUI

/// How timed lyrics are shown. Chosen in Settings › Display.
///
/// Highlighting and following are separate things here: the amber sweep, the
/// lift of the word being sung and the swell on the beat are the highlighting;
/// the line in the middle moving on with the song is the following. Some
/// singers find the sweep a distraction but still want the words to keep up,
/// and some want the whole song in front of them to read at their own pace.
enum LyricsStyle: String, CaseIterable, Identifiable {
    case highlight
    case follow
    case page

    static let defaultsKey = "lyricsStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highlight: return "Highlight as sung"
        case .follow:    return "Follow, no highlight"
        case .page:      return "Full lyrics"
        }
    }

    var detail: String {
        switch self {
        case .highlight:
            return "Each word lights up as it's sung, and the lines move on with the song."
        case .follow:
            return "The lines still move on with the song, in plain white — no sweep across the words and nothing pulsing on the beat."
        case .page:
            return "The whole song on one page, still. Nothing moves by itself; scroll to read ahead."
        }
    }
}

/// Lyrics as a teleprompter push. The line being sung sits large in the middle
/// with the next line smaller beneath it. When the line changes, the old line
/// pans up and fades, the preview line rises into its place and grows to full
/// size, and a new preview fades in beneath.
///
/// The rise-and-grow only works because each line keeps its identity across the
/// change — the middle line is not replaced, it is restyled, so SwiftUI animates
/// its position and size instead of cross-fading two separate views.
struct LyricsStage: View {
    let lines: [LyricLine]
    let position: Double
    let activeIndex: Int?
    let fontSize: CGFloat
    let tempo: Double?
    let beatOffset: Double
    /// Off for `LyricsStyle.follow`: lines move on, words are never swept.
    var highlight: Bool = true
    let onJump: (LyricLine) -> Void

    /// Each row's laid-out height, by line. See `slots(in:)`.
    @State private var heights: [Int: CGFloat] = [:]

    /// 1 on the beat, decaying to roughly 0 by the next one. Uses the same grid
    /// the background pulses on, so the lyrics and the field breathe together.
    private var beatPulse: Double {
        guard let tempo, tempo >= 40, tempo <= 250 else { return 0 }
        let beat = 60.0 / tempo
        var phase = (position - beatOffset).truncatingRemainder(dividingBy: beat)
        if phase < 0 { phase += beat }
        return exp(-4.0 * phase / beat)
    }

    /// Line changes take half a beat — an eighth note — so the push lands in
    /// time with the music.
    ///
    /// A full beat sounds right but measures wrong: clamped for readability it
    /// came out at the ceiling for everything from 60 to 140 BPM, which is most
    /// music, so every song moved identically. Half a beat spreads the range
    /// where songs actually live.
    private var transitionDuration: Double {
        guard let tempo, tempo >= 40, tempo <= 250 else { return 0.26 }
        return min(0.42, max(0.16, 30.0 / tempo))
    }

    var body: some View {
        // Every row is laid out at the full font size and only *scaled* visually.
        // Animating the real font size makes FlowLayout re-measure each frame, so
        // words hop between wrapped rows mid-animation — that was the glitch.
        // Slots are positioned explicitly so a scaled row can't disturb layout.
        GeometryReader { geo in
            let slot = slots(in: geo.size)
            ZStack {
                if let index = activeIndex, lines.indices.contains(index) {
                    GhostAsides(line: lines[index],
                                position: position,
                                fontSize: fontSize,
                                size: geo.size)
                }

                ForEach(window, id: \.line.id) { entry in
                    LyricRow(
                        line: entry.line,
                        isActive: entry.isActive,
                        fontSize: fontSize,
                        position: position,
                        highlight: highlight)
                        .frame(width: max(1, geo.size.width - 112))
                        // Measured before the scale and position: this is the
                        // height the row lays out at, which scaling never changes.
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                            heights[entry.line.id] = height
                        }
                        // The lead line swells a little on each beat; the
                        // preview stays still so only one thing is moving.
                        // Without highlighting nothing pulses at all.
                        .scaleEffect(entry.isActive ? 1 + (highlight ? 0.018 * beatPulse : 0) : 0.42,
                                     anchor: .center)
                        .position(x: geo.size.width / 2,
                                  y: entry.isActive ? slot.active : slot.preview)
                        .id(entry.line.id)
                        .transition(.asymmetric(
                            // Leaving: pan up and fade. Arriving: fade in below.
                            insertion: .opacity,
                            removal: .offset(y: -fontSize * 1.1).combined(with: .opacity)))
                        .contentShape(Rectangle())
                        .onTapGesture { if entry.isActive { onJump(entry.line) } }
                }
            }
            .animation(.easeOut(duration: transitionDuration), value: activeIndex)
        }
    }

    /// Where the two lines sit: 44% and 76% of the height, as always — unless
    /// the line being sung is tall enough to reach the preview. A line that
    /// wrapped to three rows ran down into the next line's preview and the two
    /// were drawn over each other; seen live at the 80 pt size. The preview now
    /// sits below the sung line's real bottom edge, and if that would take it
    /// off the screen, both rise together without the sung line leaving the top.
    private func slots(in size: CGSize) -> (active: CGFloat, preview: CGFloat) {
        let entries = window
        let activeHeight = entries.first { $0.isActive }.flatMap { heights[$0.line.id] } ?? 0
        let previewHeight = (entries.first { !$0.isActive }.flatMap { heights[$0.line.id] } ?? 0) * 0.42

        var active = size.height * 0.44
        var preview = max(size.height * 0.76,
                          active + activeHeight * 1.02 / 2 + fontSize * 0.35 + previewHeight / 2)

        let margin = fontSize * 0.4
        let overflow = preview + previewHeight / 2 - (size.height - margin)
        if overflow > 0 {
            let lift = min(overflow, max(0, active - activeHeight / 2 - margin))
            active -= lift
            preview -= lift
        }
        return (active, preview)
    }

    /// The line being sung plus the one after it. Before the first line starts,
    /// the opening line waits in the preview slot so it grows into place rather
    /// than appearing from nothing.
    private var window: [(line: LyricLine, isActive: Bool)] {
        guard !lines.isEmpty else { return [] }

        guard let activeIndex, lines.indices.contains(activeIndex) else {
            return lines.first(where: { $0.hasLead }).map { [($0, false)] } ?? []
        }

        // A line that is entirely backing vocals has no lead to show — it floats
        // as ghosts instead. Taking the lead slot blanked the display and pulled
        // the preview line up early, which is why the next lyric appeared before
        // it was sung.
        let leadIndex = (0...activeIndex).reversed().first { lines[$0].hasLead }
        let nextIndex = lines.indices.first { $0 > activeIndex && lines[$0].hasLead }

        var entries: [(line: LyricLine, isActive: Bool)] = []
        if let leadIndex {
            entries.append((lines[leadIndex], true))
        }
        if let nextIndex {
            entries.append((lines[nextIndex], false))
        }
        return entries
    }
}

// MARK: - Rows

private struct LyricRow: View {
    let line: LyricLine
    let isActive: Bool
    let fontSize: CGFloat
    let position: Double
    let highlight: Bool

    var body: some View {
        Group {
            if line.isBlank {
                InstrumentalPulse(progress: isActive ? line.progress(at: position) : 0)
            } else {
                words
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var words: some View {
        let state = isActive && highlight ? line.wordState(at: position) : nil
        // Unhighlighted, the line being sung is plain full white: dimmed like
        // an upcoming line, it would read as not started yet, all the way through.
        let base = isActive && !highlight ? 0.96 : 0.45

        return FlowLayout(spacing: fontSize * 0.30, lineSpacing: fontSize * 0.24) {
            ForEach(line.leadWords) { word in
                // .equatable() so only the word actually being sung re-renders.
                // Every other word's fill is a constant 0 or 1 from frame to
                // frame, and re-rendering all of them at up to 120fps was most
                // of the per-frame cost on this view.
                WordView(text: word.text,
                         fill: Self.fill(for: word.id, state: state),
                         lift: fontSize * 0.055,
                         base: base)
                    .equatable()
            }
        }
        .font(.system(size: fontSize, weight: .heavy, design: .rounded))
    }

    /// 1 once sung, the sweep fraction while being sung, 0 before.
    private static func fill(for offset: Int,
                             state: (index: Int, fraction: Double)?) -> Double {
        guard let state else { return 0 }
        if offset < state.index { return 1 }
        if offset == state.index { return state.fraction }
        return 0
    }
}

/// Backing vocals and ad-libs — the parts written in parentheses — drifting in
/// around the lead line rather than crowding it.
///
/// Placement is hashed from the line and phrase index rather than actually
/// random: it has to be identical on every frame, or they would scatter anew
/// sixty times a second. Positions avoid the middle band where the lead sits.
/// The phrases themselves are grouped at parse time, not here.
private struct GhostAsides: View {
    let line: LyricLine
    let position: Double
    let fontSize: CGFloat
    let size: CGSize

    var body: some View {
        ForEach(line.asides) { phrase in
            let spot = place(phrase.id)
            Text(phrase.text)
                .font(.system(size: fontSize * 0.46 * spot.scale,
                              weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.34))
                .rotationEffect(.degrees(spot.tilt))
                // Drifts slightly larger across its life, so it breathes rather
                // than sitting there like a pasted-on label.
                .scaleEffect(growth(for: phrase))
                .position(x: spot.x, y: spot.y)
                .opacity(opacity(for: phrase))
        }
    }

    /// Gentle swell from just under to just over full size.
    private func growth(for aside: LyricAside) -> CGFloat {
        let span = max(0.3, aside.end - aside.start)
        let life = min(1.4, max(0, (position - aside.start) / span))
        return 0.93 + 0.15 * life
    }

    private func opacity(for aside: LyricAside) -> Double {
        let rise = 0.3, fall = 1.1
        if position < aside.start { return 0 }
        if position < aside.start + rise { return (position - aside.start) / rise }
        if position < aside.end { return 1 }
        let after = position - aside.end
        return after < fall ? 1 - after / fall : 0
    }

    private func place(_ seed: Int) -> (x: CGFloat, y: CGFloat, tilt: Double, scale: CGFloat) {
        let a = hash(Double(line.id) * 7.31 + Double(seed) * 3.17)
        let b = hash(Double(line.id) * 2.71 + Double(seed) * 9.13 + 4.0)
        let c = hash(Double(line.id) * 5.11 + Double(seed) * 1.87 + 9.0)
        let d = hash(Double(line.id) * 3.77 + Double(seed) * 6.29 + 13.0)

        // Keep out of the middle third, where the lead line lives.
        let band = b < 0.5 ? 0.08 + 0.20 * (b * 2) : 0.66 + 0.24 * ((b - 0.5) * 2)
        return (x: size.width * (0.12 + 0.76 * a),
                y: size.height * band,
                tilt: -8 + 16 * c,
                // Spread of sizes so no two ghosts read as the same label.
                scale: CGFloat(0.78 + 0.62 * d))
    }

    private func hash(_ x: Double) -> Double {
        let v = sin(x) * 43758.5453
        return v - floor(v)
    }
}

/// One word of the line.
///
/// Every phase renders the *same* view — a dim word with an amber copy overlaid
/// and masked to `fill`. Branching on phase instead (bare Text when upcoming, a
/// ZStack while singing) makes each word rebuild structurally twice per line,
/// which re-measures the row and shifts it by fractions of a point. It also caps
/// the sweep short: swapping to a flat amber Text at the moment the next word
/// starts means the mask never visibly reaches the end of the word.
private struct WordView: View, Equatable {
    let text: String
    let fill: Double
    let lift: CGFloat
    /// Opacity of the unsung word.
    var base: Double = 0.45

    /// Rises as the sweep crosses it and settles as it finishes — so each word
    /// is picked out as it's sung, without the glow that made it look smeared.
    /// A sine arch means it starts and ends exactly level, with no snap.
    private var rise: CGFloat {
        guard fill > 0, fill < 1 else { return 0 }
        return lift * CGFloat(sin(Double.pi * fill))
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.white.opacity(base))
            .overlay(alignment: .leading) {
                Text(text)
                    .foregroundStyle(Theme.sung)
                    // A single word never wraps, so the mask lines up with the
                    // glyphs exactly — this is where scaleEffect is precise.
                    .mask(alignment: .leading) {
                        Rectangle().scaleEffect(x: max(0.0001, fill), anchor: .leading)
                    }
            }
            // offset, not padding: a transform can't disturb the row's layout.
            .offset(y: -rise)
    }
}

/// Wraps words across rows and centres each row. Written against the `Layout`
/// protocol rather than a GeometryReader — measurement happens during layout,
/// so there is no second pass for the highlight to fall out of step with.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 10

    struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// SwiftUI calls sizeThatFits and placeSubviews back to back, and this view
    /// rebuilds on every frame at up to 120fps. Measuring each word twice per
    /// frame is wasted work, and re-measuring is where sub-point drift creeps in.
    struct Cache {
        var width: CGFloat = -1
        var rows: [Row] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.width = -1        // subview set changed; measure again
    }

    private func rows(_ subviews: Subviews, maxWidth: CGFloat, cache: inout Cache) -> [Row] {
        if cache.width == maxWidth, !cache.rows.isEmpty { return cache.rows }
        let computed = measure(subviews, maxWidth: maxWidth)
        cache.width = maxWidth
        cache.rows = computed
        return computed
    }

    private func measure(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width

            if !current.items.isEmpty && projected > maxWidth {
                rows.append(current)
                current = Row(items: [(index, size)], width: size.width, height: size.height)
            } else {
                current.items.append((index, size))
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(subviews, maxWidth: maxWidth, cache: &cache)
        let height = rows.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(rows.map(\.width).max() ?? 0, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for row in rows(subviews, maxWidth: bounds.width, cache: &cache) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}

/// Blank LRC lines are instrumental gaps. A row that breathes beats a row that
/// looks like the app has frozen.
private struct InstrumentalPulse: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { index in
                let phase = min(1, max(0, progress * 3 - Double(index)))
                Circle()
                    .fill(.white.opacity(0.3 + 0.5 * phase))
                    .frame(width: 13, height: 13)
                    .scaleEffect(1 + 0.35 * phase)
            }
        }
    }
}

/// Fills the long gaps — intro, solo, outro — with a countdown to the next line
/// so nobody is left staring at a still screen wondering if the app froze.
struct CueCountdown: View {
    let secondsRemaining: Double

    var body: some View {
        let total = 4.0
        let filled = Int(ceil(min(total, max(0, secondsRemaining))))

        HStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Theme.cue : Theme.cue.opacity(0.15))
                    .frame(width: 11, height: 11)
                    .scaleEffect(index == filled - 1 ? 1.35 : 1)
                    .animation(.easeOut(duration: 0.2), value: filled)
            }
        }
    }
}
