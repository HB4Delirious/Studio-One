import SwiftUI

/// Tap-to-time: fix or create timed lyrics by tapping along once.
///
/// For a song LRCLIB has only untimed words for, timings that drift, or no
/// lyrics at all (paste them in). The song restarts from the top; a tap marks
/// the moment each line starts, heard rather than played — the output delay is
/// taken off — and the result is saved for that song, ahead of anything
/// downloaded. Word timing inside a line is estimated as it is for any
/// line-timed lyrics.
struct LyricsTimingSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case edit, tapping, done }

    @State private var phase = Phase.edit
    @State private var text = ""
    @State private var lines: [String] = []
    /// Everything tapped so far, in order. A gap is an entry with no text.
    @State private var taps: [(time: Double, text: String)] = []
    @State private var next = 0
    @State private var alsoShare = false
    @State private var confirmShare = false
    @FocusState private var tapFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            Group {
                switch phase {
                case .edit:    editor
                case .tapping: tapper
                case .done:    finished
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 620, height: 500)
        .background(Theme.panel)
        .onAppear { text = model.linesForTiming }
        .confirmationDialog("Share your timing publicly?", isPresented: $confirmShare) {
            Button("Share on LRCLIB") {
                model.shareTiming()
                dismiss()
            }
        } message: {
            Text(shareExplanation)
        }
        .onDisappear { model.isTimingLyrics = false }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Time the lyrics").font(.system(size: 16, weight: .semibold))
                Text(model.track.map { "\($0.name) — \($0.artist)" } ?? "Nothing playing")
                    .font(.system(size: 12)).foregroundStyle(Theme.upcoming).lineLimit(1)
            }
            Spacer()
            Button(phase == .edit ? "Cancel" : "Stop") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Edit

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One line of the song per line. Paste lyrics in if there were none. When you start, the song goes back to the beginning: press Space as each line starts to be sung.")
                .font(.system(size: 12)).foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
            HStack {
                if model.lyricsTimedByYou {
                    Button("Use LRCLIB's timing instead") {
                        model.discardTiming()
                        dismiss()
                    }
                    .help("Forget your timing for this song")
                    Button("Share on LRCLIB…") { confirmShare = true }
                        .disabled(model.sharingTiming)
                        .help("Publish your timing so other players get it too")
                }
                Spacer()
                Text("\(parsedLines.count) lines").font(Theme.label).foregroundStyle(Theme.upcoming)
                Button("Start from the top") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedLines.isEmpty || model.track == nil)
            }
        }
    }

    private var parsedLines: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func start() {
        lines = parsedLines
        taps = []
        next = 0
        model.isTimingLyrics = true
        model.seek(to: 0)
        if !model.isPlaying { model.togglePlayback() }
        phase = .tapping
        tapFocus = true
    }

    // MARK: Tapping

    private var tapper: some View {
        VStack(spacing: 18) {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                HStack {
                    Text("Line \(min(next + 1, lines.count)) of \(lines.count)")
                    Spacer()
                    Text(Self.clock(model.heardPosition)).monospacedDigit()
                }
                .font(Theme.label).foregroundStyle(Theme.upcoming)
            }

            VStack(spacing: 12) {
                Text(lastTapped)
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.35))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(next < lines.count ? lines[next] : "")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.sung)
                    .lineLimit(3).multilineTextAlignment(.center)
                Text(next + 1 < lines.count ? lines[next + 1] : "")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 190)

            HStack(spacing: 10) {
                Button("Undo  ⌫") { undo() }.disabled(taps.isEmpty)
                Button("Break  G") { gap() }
                    .help("An instrumental break: nothing is lit until the next line")
                Spacer()
                Button { tap() } label: {
                    Text("Tap  ␣").frame(width: 120)
                }
                .controlSize(.large)
            }
        }
        // Keys go to this view, not a text field: Space taps.
        .focusable()
        .focusEffectDisabled()
        .focused($tapFocus)
        .onKeyPress(.space) { tap(); return .handled }
        .onKeyPress(.delete) { undo(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "gG")) { _ in gap(); return .handled }
        .onAppear { tapFocus = true }
    }

    private var lastTapped: String {
        guard let last = taps.last else { return "Press Space as the first line starts." }
        return last.text.isEmpty ? "— break —" : last.text
    }

    private func tap() {
        guard phase == .tapping, next < lines.count else { return }
        taps.append((model.heardPosition, lines[next]))
        next += 1
        if next == lines.count { phase = .done }
    }

    private func gap() {
        guard phase == .tapping, let last = taps.last, !last.text.isEmpty else { return }
        taps.append((model.heardPosition, ""))
    }

    private func undo() {
        guard let last = taps.popLast() else { return }
        if !last.text.isEmpty { next = max(0, next - 1) }
        if phase == .done { phase = .tapping; tapFocus = true }
    }

    // MARK: Done

    private var finished: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("All \(lines.count) lines timed.")
                .font(.system(size: 18, weight: .semibold))
            Text("Saved for this song only, and used ahead of LRCLIB from now on. Reload lyrics leaves it alone; to go back, open this again and choose LRCLIB's timing.")
                .font(.system(size: 12)).foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Also share it on LRCLIB (public)", isOn: $alsoShare)
                .font(.system(size: 12))
                .help(shareExplanation)
            Spacer()
            HStack {
                Button("Undo last tap") { undo() }
                Button("Start over") { start() }
                Spacer()
                Button(alsoShare ? "Save and share" : "Save") {
                    model.saveTiming(taps, thenShare: alsoShare)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var shareExplanation: String {
        let song = model.track.map { "“\($0.name)” by \($0.artist)" } ?? "this song"
        return "Your timing for \(song) goes to LRCLIB, the public lyrics database this app and many other players read from, so the next person gets it timed. Anyone can see and use it."
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
