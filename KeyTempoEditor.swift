import SwiftUI

/// The song's key and tempo under its title in the Controls window, editable
/// in place: one question at a time, rather than a window — letter, then
/// accidental, then major/minor, then BPM.
struct KeyTempoEditor: View {
    @EnvironmentObject private var model: KaraokeModel
    private enum Step: Equatable { case idle, letter, accidental, quality, tempo }
    @State private var step: Step = .idle
    @State private var letter = "C"
    @State private var accidental = ""
    @State private var isMinor = false
    @State private var bpmField = ""
    @FocusState private var bpmFocused: Bool

    var body: some View {
        musicalInfo
    }

    /// Key and tempo, editable in place, one question at a time.
    private var musicalInfo: some View {
        Group {
            switch step {
            case .idle:       readout
            case .letter:     letterStep
            case .accidental: accidentalStep
            case .quality:    qualityStep
            case .tempo:      tempoStep
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .animation(.easeInOut(duration: 0.18), value: step)
        .animation(.easeInOut(duration: 0.25), value: model.publishedAnalysis)
    }

    /// Normal display, identical whether the values came from an API or by hand.
    @ViewBuilder
    private var readout: some View {
        let analysis = model.publishedAnalysis
        let suspect = analysis?.halfTimeSuspect == true

        if analysis == nil {
            Button {
                beginEntry()
            } label: {
                Label("Set Key / BPM", systemImage: "plus.circle")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondary)
            .help("No source has key or tempo for this track — enter them by hand")
        } else {
            HStack(spacing: 10) {
                // Both always shown, "—" when unset.
                HStack(spacing: 5) {
                    labelledValue("KEY", analysis?.key ?? "—")
                        .foregroundStyle(model.manualKey != nil ? Theme.cue : .white)
                    KeyCheckBadge()
                }

                HStack(spacing: 5) {
                    labelledValue("BPM", TrackAnalysis.bpmText(analysis?.tempo))
                        .foregroundStyle(model.manualTempo != nil ? Theme.cue : .white)

                    if suspect {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.cue)
                            .help("The two sources disagree by 2× — this may be half-time. Use ×2 or ÷2 to correct it.")
                    }
                }

                HStack(spacing: 4) {
                    tempoButton("÷2", to: model.tempoMultiplier / 2,
                                active: model.tempoMultiplier < 1)
                    tempoButton("×2", to: model.tempoMultiplier * 2,
                                active: model.tempoMultiplier > 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { beginEntry() }
            .help("Click to set the key and tempo by hand")
        }
    }


    // MARK: Entry steps

    private var letterStep: some View {
        HStack(spacing: 3) {
            ForEach(["A", "B", "C", "D", "E", "F", "G"], id: \.self) { note in
                chip(note) {
                    letter = note
                    step = .accidental
                }
            }
            if model.hasManualValues {
                chip("Auto", width: 34) {
                    model.manualKey = nil
                    model.manualTempo = nil
                    step = .idle
                }
            }
            cancelChip
        }
    }

    private var accidentalStep: some View {
        HStack(spacing: 4) {
            stepLabel(letter)
            // Natural too, or the plain keys would be unreachable.
            chip("♮", width: 32) { accidental = ""; step = .quality }
            chip("♯", width: 32) { accidental = "♯"; step = .quality }
            chip("♭", width: 32) { accidental = "♭"; step = .quality }
            cancelChip
        }
    }

    private var qualityStep: some View {
        HStack(spacing: 4) {
            stepLabel(letter + accidental)
            chip("major", width: 50) { isMinor = false; step = .tempo }
            chip("minor", width: 50) { isMinor = true; step = .tempo }
            cancelChip
        }
    }

    private var tempoStep: some View {
        HStack(spacing: 5) {
            stepLabel(letter + accidental + (isMinor ? "m" : ""))

            Text("BPM")
                .font(Theme.label)
                .foregroundStyle(Theme.secondary)

            TextField("120", text: $bpmField)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .focused($bpmFocused)
                .onSubmit { commit() }

            chip("Save", width: 40) { commit() }
            cancelChip
        }
        .onAppear { bpmFocused = true }
    }

    // MARK: Entry plumbing

    private func beginEntry() {
        // Starts from what's showing, read the way MIDI reads it, so opening
        // and saving without a change changes nothing.
        if let key = model.publishedAnalysis?.key, let coded = MIDIBridge.encode(key: key) {
            let name = MIDIBridge.decode(root: coded.root, minor: false)
            letter = String(name.prefix(1))
            accidental = name.contains("♯") ? "♯" : ""
            isMinor = coded.minor
        }
        if let tempo = model.publishedAnalysis?.tempo, tempo > 0 {
            bpmField = String(format: "%.0f", tempo)
        }
        step = .letter
    }

    private func commit() {
        model.manualKey = letter + accidental + (isMinor ? "m" : "")
        // Empty clears the tempo; anything else must read as a number (a
        // comma counts as a decimal point) and is kept to 20–400.
        let trimmed = bpmField.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.manualTempo = nil
        } else if let typed = Double(scripted: trimmed), typed.isFinite {
            model.manualTempo = min(400, max(20, (typed * 10).rounded() / 10))
        }
        bpmFocused = false
        bpmField = ""
        step = .idle
    }

    private var cancelChip: some View {
        chip("✕", width: 24) {
            bpmFocused = false
            step = .idle
        }
    }

    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.cue)
            .frame(minWidth: 26)
    }

    private func chip(_ label: String, width: CGFloat = 23,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: width + 4, height: 24)
                .background(Color.white.opacity(0.13), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tempoButton(_ label: String, to multiplier: Double, active: Bool) -> some View {
        Button {
            model.tempoMultiplier = min(4, max(0.25, multiplier))
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? Theme.backdrop : .white.opacity(0.75))
                .frame(width: 34, height: 24)
                .background(active ? Theme.cue : Color.white.opacity(0.10), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(multiplier < 0.25 || multiplier > 4)
        .help(model.tempoMultiplier == 1
              ? "Halve or double the tempo sent to Logic"
              : String(format: "Correction ×%.2g — click the other to undo", model.tempoMultiplier))
    }

    private func labelledValue(_ caption: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(caption)
                .font(Theme.label)
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

/// Which player Studio One follows, at the top of the sidebar. Switching
/// rebuilds the controller live.
struct SourceSwitch: View {
    @EnvironmentObject private var model: KaraokeModel

    var body: some View {
        Picker("Player", selection: Binding(
            get: { model.musicSource },
            set: { model.changeSource(to: $0) })) {
                ForEach(MusicSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help("Follow Spotify or Apple Music")
    }
}

/// The lyrics window's text size, as a small capsule: on the stage preview's
/// corner, or beside the song's tools without one. The preview itself keeps
/// its own size (see `StagePreview`).
struct LyricSizeStepper: View {
    @AppStorage(LyricSize.key) private var fontSize = LyricSize.standard

    var body: some View {
        HStack(spacing: 2) {
            // Framed larger than the glyphs, to be easy to hit.
            Button { fontSize = LyricSize.clamped(fontSize - 4) } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .accessibilityLabel("Smaller lyrics")
            .help("Smaller lyrics")
            .disabled(fontSize <= LyricSize.range.lowerBound)
            Text("\(Int(fontSize))")
                .font(Theme.timecode)
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 22)
            Button { fontSize = LyricSize.clamped(fontSize + 4) } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .accessibilityLabel("Larger lyrics")
            .help("Larger lyrics")
            .disabled(fontSize >= LyricSize.range.upperBound)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .help("Lyric size in the lyrics window, in points")
    }
}

/// Beside KEY: whether MetaTune on Mic 1 shows the key Studio One sent, as
/// the key check reads it (see `KeyCheck`). Nothing while the check is off.
private struct KeyCheckBadge: View {
    @ObservedObject private var check = KeyCheck.shared

    var body: some View {
        switch check.status {
        case .off:
            EmptyView()
        case .notReady(let why):
            mark("questionmark.circle", Theme.secondary, "Key check: \(why)")
        case .waiting(let key):
            mark("ellipsis.circle", Theme.secondary, "Sent \(key); checking MetaTune on Mic 1…")
        case .landed(let key):
            mark("checkmark.circle.fill", Theme.cue, "MetaTune on Mic 1 shows \(key)")
        case .missed(let expected, let shows):
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Not in Logic")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.orange)
            .help("Sent \(expected), but MetaTune on Mic 1 shows \(shows). Is an alert open in Logic, or a control surface on the “Studio One” port?")
        case .bypassed:
            mark("slash.circle", Theme.secondary, "MetaTune on Mic 1 is bypassed")
        }
    }

    private func mark(_ symbol: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .help(help)
    }
}
