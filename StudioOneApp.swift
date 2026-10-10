import SwiftUI

@main
struct StudioOneApp: App {

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
        // The toolbar says what the window is; the title "Controls" stays for
        // the Window menu.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            PlaybackCommands(model: model)
        }

        // A window of its own, to go full screen on a second display. A Window,
        // not a WindowGroup, so opening it again brings back the same one.
        Window("Lyrics", id: Self.lyricsWindowID) {
            LyricsWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 620)
        // A Window's default sizes to its content and can't be resized, which
        // rules out full screen.
        .windowResizability(.contentMinSize)
        // Nothing but the lyrics: the buttons come back with the mouse.
        .windowStyle(.hiddenTitleBar)

        MenuBarReadout(model: model)
    }
}

private struct PlaybackCommands: Commands {
    @ObservedObject var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BrowserWindow.sidebarHiddenKey) private var sidebarHidden = false
    @AppStorage(LightShow.enabledKey) private var lightsOn = false
    @AppStorage(LightShow.blackoutKey) private var blackout = false

    var body: some Commands {
        // Beside the toolbar's own View menu items.
        CommandGroup(before: .toolbar) {
            Button(sidebarHidden ? "Show Sidebar" : "Hide Sidebar") { sidebarHidden.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.shared.checkFromMenu() } }
        }

        CommandGroup(replacing: .help) {
            Button("Setup Assistant…") {
                openWindow(id: StudioOneApp.controlsWindowID)
                SetupAssistant.shared.shown = true
            }
        }

        CommandMenu("Playback") {
            // Given up while lyrics are being tapped out, where Space is the tap.
            Button("Play or Pause") { model.togglePlayback() }
                .keyboardShortcut(model.isTimingLyrics ? nil : KeyboardShortcut(.space, modifiers: []))
            Button("Next Track") { model.nextTrack() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Previous Track") { model.previousTrack() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button("Fade Out") { model.fadeOut() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Divider()

            Button("Nudge Lyrics Later") { model.offsetMilliseconds -= 50 }
                .keyboardShortcut("[", modifiers: [])
            Button("Nudge Lyrics Earlier") { model.offsetMilliseconds += 50 }
                .keyboardShortcut("]", modifiers: [])
            Button("Sync: A Line Starts Now") { model.syncToLineNow() }
                .keyboardShortcut("\\", modifiers: [])
            Button("Reset Sync") { model.offsetMilliseconds = 0 }
                .keyboardShortcut("0", modifiers: [.command])

            Divider()

            Button("Reload Lyrics") { model.reloadLyrics() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Bring \(model.musicSource.displayName) Forward") { model.revealPlayer() }
            if lightsOn {
                Toggle("Blackout", isOn: $blackout)
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            Divider()

            Button("Lyrics Window") {
                openWindow(id: StudioOneApp.lyricsWindowID)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Controls Window") {
                openWindow(id: StudioOneApp.controlsWindowID)
            }
            .keyboardShortcut("k", modifiers: [.command])
        }
    }
}
