import SwiftUI

/// Key and tempo in the system menu bar, so they can be read without bringing
/// a window forward — useful when the lyrics are full-screen on another
/// display and the controls are behind them.
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
            MenuBarContent(model: model)
        } label: {
            // The warning triangle is the same half-time signal the control bar
            // shows; without it a wrong tempo looks authoritative up here.
            Text(model.publishedAnalysis.map {
                $0.summary + ($0.halfTimeSuspect ? " ⚠︎" : "")
            } ?? "♪ —")
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let track = model.track {
            Text(track.name)
            Text(track.artist)
            Divider()
        }

        let analysis = model.publishedAnalysis
        Text("Key: \(analysis?.key ?? "—")\(model.manualKey != nil ? " (set by hand)" : "")")
        Text("BPM: \(TrackAnalysis.bpmText(analysis?.tempo))\(model.manualTempo != nil ? " (set by hand)" : "")")

        if analysis?.halfTimeSuspect == true {
            Text("Sources disagree by 2× — may be half-time")
        }

        if analysis?.tempo != nil {
            Divider()
            Button("Halve the tempo") { model.tempoMultiplier /= 2 }
            Button("Double the tempo") { model.tempoMultiplier *= 2 }
            if model.tempoMultiplier != 1 {
                Button("Reset the tempo") { model.tempoMultiplier = 1 }
            }
        }

        Divider()
        Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayback() }
        Button("Lyrics window") { openWindow(id: SpotifyKaraokeApp.lyricsWindowID) }
        Button("Controls window") { openWindow(id: SpotifyKaraokeApp.controlsWindowID) }
    }
}
