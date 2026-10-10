import SwiftUI

/// A playlist prepared for the night (see `Preparation`): how far it's got,
/// then every song with what was found, and the ones to look at with a way to
/// start fixing them — play it, then time its lyrics or set its key.
struct PrepareSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var preparation = Preparation.shared
    @Environment(\.dismiss) private var dismiss
    let playlist: LibraryPlaylist
    @State private var onlyAttention = false

    private var isThisPlaylist: Bool { preparation.playlist == playlist }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prepare “\(playlist.name)”").font(.system(size: 16, weight: .semibold))
                    Text("Every song's lyrics, key and tempo, looked up now and kept on this Mac — ready the moment each song starts, even if the Wi-Fi isn't. A key marked with Wi-Fi came from the song's preview and is worked out again as it plays.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Theme.hairline)

            summary
                .padding(.horizontal, 20).padding(.vertical, 12)

            if isThisPlaylist, !preparation.songs.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(preparation.songs.enumerated()), id: \.element.id) { index, song in
                            if !onlyAttention || song.needsAttention {
                                row(index + 1, song)
                                Divider().overlay(Theme.hairline)
                            }
                        }
                    }
                }
            } else {
                Spacer()
            }

            HStack {
                if isThisPlaylist, preparation.finishedCount > 0 {
                    Picker("Show", selection: $onlyAttention) {
                        Text("All Songs").tag(false)
                        Text("To Look At (\(preparation.attentionCount))").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                Spacer()
                if isThisPlaylist, preparation.running {
                    Button("Stop") { preparation.stop() }
                } else {
                    Button(isThisPlaylist && !preparation.songs.isEmpty ? "Prepare Again" : "Prepare") { start() }
                        .disabled(model.browser == nil)
                }
            }
            .controlSize(.small)
            .padding(12)
        }
        .frame(width: 720, height: 520)
        .background(Theme.panel)
        .onAppear {
            // Opened for a playlist not yet prepared: start straight away.
            if !isThisPlaylist { start() }
        }
    }

    private func start() {
        guard let browser = model.browser else { return }
        onlyAttention = false
        preparation.prepare(playlist, with: browser, source: model.musicSource)
    }

    @ViewBuilder
    private var summary: some View {
        let total = preparation.songs.count
        let done = preparation.finishedCount
        VStack(alignment: .leading, spacing: 8) {
            if isThisPlaylist, let failure = preparation.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            } else if !isThisPlaylist || (preparation.running && total == 0) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the playlist…").font(.system(size: 12))
                }
            } else {
                ProgressView(value: Double(done), total: Double(max(1, total)))
                    .tint(model.palette.accent)
                Text(summaryText(done: done, total: total))
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryText(done: Int, total: Int) -> String {
        let attention = preparation.attentionCount
        if preparation.running { return "\(done) of \(total) looked up…" }
        if done < total { return "Stopped after \(done) of \(total). Prepare Again picks up the rest; what's found is kept." }
        if attention == 0 { return "All \(total) songs are ready." }
        return "\(total - attention) of \(total) ready · \(attention) to look at — play one to time its lyrics or set its key."
    }

    private func row(_ number: Int, _ song: Preparation.Song) -> some View {
        HStack(spacing: 10) {
            Group {
                if !song.finished {
                    if preparation.running { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "circle.dashed").foregroundStyle(Theme.secondary) }
                } else if song.needsAttention {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.system(size: 12))
            .frame(width: 18)

            Text("\(number)")
                .font(Theme.timecode).foregroundStyle(Theme.secondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.track.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(song.track.artist).font(.system(size: 11))
                    .foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)

            if song.finished {
                Group {
                    if let difficulty = song.difficulty { DifficultyChip(difficulty: difficulty, compact: true) }
                }
                .frame(width: 22)
                lyricsLabel(song.lyrics)
                    .frame(width: 150, alignment: .leading)
                keyLabel(song)
                    .frame(width: 96, alignment: .leading)
            }
            Button("Play") {
                model.playChosen(song.track)
            }
            .controlSize(.mini)
            .opacity(song.needsAttention ? 1 : 0)
            .disabled(!song.needsAttention)
            .help("Play it now, to time its lyrics or set its key")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func lyricsLabel(_ lyrics: Preparation.Lyrics) -> some View {
        let (text, symbol, colour): (String, String, Color) = {
            switch lyrics {
            case .waiting:      return ("…", "ellipsis", Theme.secondary)
            case .timed:        return ("Timed lyrics", "text.quote", Theme.secondary)
            case .timedByYou:   return ("Timed by you", "hand.tap", Theme.secondary)
            case .untimed:      return ("Words only — time them", "text.alignleft", .orange)
            case .instrumental: return ("Instrumental", "music.note", Theme.secondary)
            case .none:         return ("No lyrics found", "text.badge.xmark", .orange)
            case .unreachable:  return ("Couldn't reach LRCLIB", "wifi.exclamationmark", .orange)
            }
        }()
        return Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(colour)
            .lineLimit(1)
    }

    private func keyLabel(_ song: Preparation.Song) -> some View {
        let key = song.analysis?.key
        let tempo = song.analysis?.tempo.map { TrackAnalysis.bpmText($0) }
        let text = key.map { k in tempo.map { "\(k) · \($0)" } ?? k } ?? "No key"
        let needsInternet = key != nil && !song.keyKept
        return HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11, weight: key == nil ? .semibold : .medium))
                .foregroundStyle(key == nil ? .orange : .white.opacity(0.85))
                .monospacedDigit()
            if needsInternet {
                Image(systemName: "wifi")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .lineLimit(1)
        .help(key == nil ? "Nothing found for its key: play it and set one, and it's kept for the song."
              : song.keySetByHand ? "The key you set for this song"
              : needsInternet ? "From the song's preview: worked out again as it plays, which needs the internet. Set it by hand to keep it."
              : "Key and tempo as found, kept on this Mac")
    }
}
