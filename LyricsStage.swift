import SwiftUI

/// How timed lyrics are shown. Chosen in Settings › Display.
///
/// Highlighting (the amber sweep, the lifted word, the swell on the beat) and
/// following (the line moving on with the song) are separate: some singers
/// want the words to keep up without the sweep, some the whole song at once.
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

/// The lyric text size, in points: set from the Controls window, the Stream
/// Deck and the remote, and read by both lyric views.
enum LyricSize {
    static let key = "lyricFontSize"
    static let standard: Double = 42
    static let range: ClosedRange<Double> = 24...96

    static var current: Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? standard
    }

    static func clamped(_ size: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, size))
    }
}

/// Lyrics as a teleprompter push. The line being sung sits large in the middle
/// with the next line smaller beneath it. When the line changes, the old line
/// pans up and fades, the preview line rises into its place and grows to full
/// size, and a new preview fades in beneath.
///
/// Each line keeps its identity across the change — restyled, not replaced —
/// so SwiftUI animates its position and size rather than cross-fading.
struct LyricsStage: View {
    let lines: [LyricLine]
    let position: Double
    let activeIndex: Int?
    let fontSize: CGFloat
    let tempo: Double?
    let beatOffset: Double
    /// Off for `LyricsStyle.follow`: lines move on, words are never swept.
    var highlight: Bool = true
    /// Finish the lyric: the first lead word to hide on a line, if any.
    var mask: (LyricLine) -> Int? = { _ in nil }
    /// A duet part's singer's mic level, 0…1, for its label to glow with.
    var partLevel: (LyricPart?) -> Double = { _ in 0 }
    let onJump: (LyricLine) -> Void

    /// Each row's laid-out height, by line. See `slots(in:)`.
    @State private var heights: [Int: CGFloat] = [:]

    /// 1 on the beat, decaying towards 0 by the next — the grid the background
    /// pulses on too.
    private var beatPulse: Double {
        guard let tempo, tempo >= 40, tempo <= 250 else { return 0 }
        let beat = 60.0 / tempo
        var phase = (position - beatOffset).truncatingRemainder(dividingBy: beat)
        if phase < 0 { phase += beat }
        return exp(-4.0 * phase / beat)
    }

    /// Line changes take half a beat, so the push lands in time. (A whole
    /// beat, clamped for readability, came out the same for most tempos.)
    private var transitionDuration: Double {
        guard let tempo, tempo >= 40, tempo <= 250 else { return 0.26 }
        return min(0.42, max(0.16, 30.0 / tempo))
    }

    var body: some View {
        // Rows are laid out at full size and only scaled: animating the font
        // size re-measures each frame and words hop between wrapped rows.
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
                        highlight: highlight,
                        maskFrom: mask(entry.line),
                        partLevel: entry.isActive ? partLevel(entry.line.part) : 0)
                        .frame(width: max(1, geo.size.width - 112))
                        // Before scaling, which never changes the laid-out height.
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                            heights[entry.line.id] = height
                        }
                        // Only the lead line swells on the beat, and only
                        // with highlighting on.
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

    /// Where the two lines sit: 44% and 76% of the height, unless the sung
    /// line wraps far enough to reach the preview. Then the preview sits below
    /// its real bottom edge, and if that runs off screen, both rise together.
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

    /// The line being sung and the next. Before the first starts, it waits in
    /// the preview slot, to grow into place rather than appear.
    private var window: [(line: LyricLine, isActive: Bool)] {
        guard !lines.isEmpty else { return [] }

        guard let activeIndex, lines.indices.contains(activeIndex) else {
            return lines.first(where: { $0.hasLead }).map { [($0, false)] } ?? []
        }

        // A line of backing vocals only has no lead, and floats as ghosts
        // rather than taking the lead slot.
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
    /// Words from here on are blanks, for the singer to finish.
    var maskFrom: Int?
    var partLevel: Double = 0

    var body: some View {
        Group {
            if line.isBlank {
                InstrumentalPulse(progress: isActive ? line.progress(at: position) : 0)
            } else {
                words
            }
        }
        .frame(maxWidth: .infinity)
        // A duet's line says whose it is, above the words.
        .overlay(alignment: .top) {
            if isActive, let label = line.partLabel {
                PartChip(label: label, color: Theme.part(line.part), fontSize: fontSize, level: partLevel)
                    .alignmentGuide(.top) { $0[.bottom] + fontSize * 0.28 }
            }
        }
    }

    private var words: some View {
        let state = isActive && highlight ? line.wordState(at: position) : nil
        // Unhighlighted, the sung line is plain white — dimmed, it would read
        // as not started.
        let base = isActive && !highlight ? 0.96 : 0.45

        return FlowLayout(spacing: fontSize * 0.30, lineSpacing: fontSize * 0.24) {
            ForEach(line.leadWords) { word in
                // .equatable(): only the word being sung changes from frame to
                // frame, so only it re-renders.
                WordView(text: maskFrom.map { word.id >= $0 } == true
                            ? String(repeating: "_", count: max(3, word.text.count)) : word.text,
                         fill: Self.fill(for: word.id, state: state),
                         lift: fontSize * 0.055,
                         base: base,
                         sung: Theme.part(line.part))
                    .equatable()
            }
        }
        .font(.system(size: fontSize, weight: .heavy, design: Theme.stageDesign))
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
/// Placed by a hash of line and phrase rather than at random, so it's the
/// same every frame, and kept out of the middle band where the lead sits.
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
                              weight: .medium, design: Theme.stageDesign))
                .foregroundStyle(.white.opacity(0.34))
                .rotationEffect(.degrees(spot.tilt))
                // Grows slightly over its life, so it breathes.
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
/// The same view whatever the word's state — a dim word with an amber copy
/// masked to `fill` — so a word is never rebuilt mid-line, which would
/// re-measure the row and cut the sweep short.
private struct WordView: View, Equatable {
    let text: String
    let fill: Double
    let lift: CGFloat
    /// Opacity of the unsung word.
    var base: Double = 0.45
    /// The sweep's colour: a duet part's own.
    var sung: Color = Theme.sung

    /// Rises as the sweep crosses the word and settles as it finishes: a sine
    /// arch, level at both ends, so nothing snaps.
    private var rise: CGFloat {
        guard fill > 0, fill < 1 else { return 0 }
        return lift * CGFloat(sin(Double.pi * fill))
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.white.opacity(base))
            .overlay(alignment: .leading) {
                Text(text)
                    .foregroundStyle(sung)
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

/// Wraps words across rows and centres each row. A `Layout` rather than a
/// GeometryReader, so there's no second pass for the highlight to lag.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 10

    struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// sizeThatFits and placeSubviews run back to back every frame; measuring
    /// once saves the work and the sub-point drift of measuring twice.
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

/// Blank LRC lines are instrumental gaps; a row that breathes shows the app
/// hasn't frozen.
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

/// A countdown to the next line through the long gaps — intro, solo, outro.
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

/// Whose line it is in a duet: the marker, in the part's colour.
private struct PartChip: View {
    let label: String
    let color: Color
    let fontSize: CGFloat
    /// The part's singer's mic, 0…1: the chip glows as they sing.
    var level: Double = 0

    var body: some View {
        HStack(spacing: fontSize * 0.12) {
            Circle().fill(color).frame(width: fontSize * 0.2, height: fontSize * 0.2)
            Text(label)
                .font(.system(size: fontSize * 0.32, weight: .heavy, design: Theme.stageDesign))
                .foregroundStyle(color)
        }
        .padding(.horizontal, fontSize * 0.22)
        .padding(.vertical, fontSize * 0.08)
        .background(Capsule().fill(color.opacity(0.16 + 0.3 * level)))
        .shadow(color: color.opacity(0.9 * level), radius: fontSize * 0.25 * level)
        .scaleEffect(1 + 0.08 * level)
    }
}
