import SwiftUI

/// Key and tempo in the system menu bar, so they can be read without bringing
/// a window forward — useful when the lyrics are full-screen on another
/// display and the controls are behind them. Clicked, a small panel: the song,
/// its key and tempo with ×2 / ÷2, the transport and Fade Out, so the night
/// can be run from here while Logic is in front.
///
/// A scene rather than an `NSStatusItem`: `MenuBarExtra` can read the model
/// directly, so the readout follows `publishedAnalysis` with no extra plumbing,
/// including the manual key and tempo and the ×2 / ÷2 correction.
struct MenuBarReadout: Scene {
    @ObservedObject var model: KaraokeModel
    @AppStorage(Self.enabledKey) private var enabled = true

    static let enabledKey = "menuBarReadout"

    var body: some Scene {
        MenuBarExtra(isInserted: $enabled) {
            MenuBarPanel(model: model)
        } label: {
            // The warning triangle is the same half-time signal the Controls
            // window shows; without it a wrong tempo looks authoritative here.
            Text(model.publishedAnalysis.map {
                $0.summary + ($0.halfTimeSuspect ? " ⚠︎" : "")
            } ?? "♪ —")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarPanel: View {
    @ObservedObject var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.track?.name ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    if let artist = model.track?.artist {
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if model.track != nil {
                keyAndTempo
                transport
            }

            Divider()
            HStack(spacing: 8) {
                Button("Lyrics Window") { openWindow(id: StudioOneApp.lyricsWindowID) }
                Button("Controls Window") { openWindow(id: StudioOneApp.controlsWindowID) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private var cover: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let url = model.track?.artworkURL {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
            } else if let image = model.localArtwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(shape)
    }

    private var keyAndTempo: some View {
        let analysis = model.publishedAnalysis
        return HStack(spacing: 10) {
            chip("KEY", analysis?.key ?? "—", byHand: model.manualKey != nil)
            chip("BPM", TrackAnalysis.bpmText(analysis?.tempo), byHand: model.manualTempo != nil)
            if analysis?.halfTimeSuspect == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("The sources disagree by 2× — this may be half-time")
            }
            Spacer(minLength: 0)
            if analysis?.tempo != nil {
                Button("÷2") { model.tempoMultiplier = max(0.25, model.tempoMultiplier / 2) }
                    .help("Halve the tempo sent to Logic")
                Button("×2") { model.tempoMultiplier = min(4, model.tempoMultiplier * 2) }
                    .help("Double the tempo sent to Logic")
                if model.tempoMultiplier != 1 {
                    Button("Reset") { model.tempoMultiplier = 1 }
                }
            }
        }
        .controlSize(.small)
    }

    private func chip(_ caption: String, _ value: String, byHand: Bool) -> some View {
        HStack(spacing: 4) {
            Text(caption).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(byHand ? Theme.cue : .primary)
        }
        .help(byHand ? "Set by hand" : "As found")
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button { model.previousTrack() } label: { Image(systemName: "backward.fill") }
                .help("Previous track")
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 28)
            }
            .help(model.isPlaying ? "Pause" : "Play")
            Button { model.nextTrack() } label: { Image(systemName: "forward.fill") }
                .help("Next track")
            Spacer(minLength: 0)
            Button {
                model.fading ? model.stopFade() : model.fadeOut()
            } label: {
                Label(model.fading ? "Cancel Fade" : "Fade Out", systemImage: "speaker.wave.1.fill")
            }
            .disabled(!model.isPlaying && !model.fading)
        }
        .controlSize(.regular)
    }
}
