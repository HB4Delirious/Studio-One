import SwiftUI

@main
struct SpotifyKaraokeApp: App {

    static let controlsWindowID = "controls"
    static let lyricsWindowID = "lyrics"

    @StateObject private var model = KaraokeModel()

    // Carries the Dock icon swap; see DockIcon.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Declared first, so this is what opens at launch: the controls belong on
        // your main display, and the lyrics are opened onto whichever screen you
        // want them on.
        Window("Controls", id: Self.controlsWindowID) {
            BrowserWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            PlaybackCommands(model: model)
        }

        // The lyrics stand alone so this window can be dragged to a second
        // screen and made full-screen without carrying the chrome along.
        //
        // Window, not WindowGroup: a WindowGroup spawns a fresh instance on every
        // openWindow call, so the toolbar button kept stacking up new displays.
        // A Window brings the existing one forward instead.
        Window("Lyrics", id: Self.lyricsWindowID) {
            LyricsWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 620)
        // Without this a Window defaults to .automatic, which sizes to content
        // and leaves the window non-resizable — which also disables zoom and
        // full screen. WindowGroup defaulted differently, so this only became
        // necessary when the lyrics scene became single-instance.
        .windowResizability(.contentMinSize)

        MenuBarReadout(model: model)
    }
}

private struct PlaybackCommands: Commands {
    @ObservedObject var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Playback") {
            // Given up while lyrics are being tapped out, where Space is the tap.
            Button("Play or pause") { model.togglePlayback() }
                .keyboardShortcut(model.isTimingLyrics ? nil : KeyboardShortcut(.space, modifiers: []))
            Button("Next track") { model.nextTrack() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous track") { model.previousTrack() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

            Divider()

            Button("Nudge lyrics later") { model.offsetMilliseconds -= 50 }
                .keyboardShortcut("[", modifiers: [])
            Button("Nudge lyrics earlier") { model.offsetMilliseconds += 50 }
                .keyboardShortcut("]", modifiers: [])
            Button("Sync: a line starts now") { model.syncToLineNow() }
                .keyboardShortcut("\\", modifiers: [])
            Button("Reset sync") { model.offsetMilliseconds = 0 }
                .keyboardShortcut("0", modifiers: [.command])

            Divider()

            Button("Reload lyrics") { model.reloadLyrics() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Bring \(model.musicSource.displayName) forward") { model.revealPlayer() }

            Divider()

            Button("Lyrics window") {
                openWindow(id: SpotifyKaraokeApp.lyricsWindowID)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Controls window") {
                openWindow(id: SpotifyKaraokeApp.controlsWindowID)
            }
            .keyboardShortcut("k", modifiers: [.command])
        }
    }
}
