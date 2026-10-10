import AppKit
import SwiftUI

/// The lyrics display, on its own so it can live full-screen on a second screen
/// or a TV while the controls stay on your main display.
///
/// No title bar, full screen or not: the room sees the lyrics and nothing
/// else. Moving the mouse over it brings back the window's buttons and a way
/// to the Controls window for a few seconds.
struct LyricsWindow: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(LyricSize.key) private var fontSize = LyricSize.standard
    @Environment(\.openWindow) private var openWindow
    @State private var isFullScreen = false
    @State private var chromeShown = false
    @State private var hideChrome: Task<Void, Never>?
    // A reference box, not @State: storing the window in @State would
    // invalidate the view, re-run updateNSView and store it again, forever.
    @State private var host = WindowHolder()

    var body: some View {
        LyricsPane(fontSize: CGFloat(fontSize))
            .frame(minWidth: 480, minHeight: 320)
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
            .overlay(alignment: .topTrailing) {
                if chromeShown, !isFullScreen {
                    Button {
                        openWindow(id: StudioOneApp.controlsWindowID)
                    } label: {
                        Label("Controls", systemImage: "slider.horizontal.3")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .glassButton()
                    .help("Bring back the Controls window")
                    .padding(10)
                    .transition(.opacity)
                }
            }
            // No title bar to drag it by — onto the TV, say — so a drag
            // anywhere moves it. A click, without moving, still seeks.
            .simultaneousGesture(windowDrag)
            .onContinuousHover { phase in
                switch phase {
                case .active: showChrome()
                case .ended:  setChrome(false)
                }
            }
            .background(WindowReader { window in
                host.window = window
                // SwiftUI makes every scene after the first *auxiliary*, whose
                // green button zooms instead of going full screen — and
                // fullScreenPrimary does nothing while that flag is set.
                window.collectionBehavior.remove(.fullScreenAuxiliary)
                window.collectionBehavior.remove(.fullScreenNone)
                window.collectionBehavior.insert(.fullScreenPrimary)
                applyChrome()
            })
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didEnterFullScreenNotification)) { note in
                if isThisWindow(note) { isFullScreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didExitFullScreenNotification)) { note in
                if isThisWindow(note) { isFullScreen = false }
            }
            // start() is idempotent, and both windows call it — whichever opens
            // first wins. Polling is deliberately not stopped when a window
            // closes, or shutting the lyrics window would halt the controls too.
            .onAppear { model.start() }
    }

    /// Hands the drag to the window, which follows the mouse until it's let
    /// go; the gesture only notices that one began.
    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                guard let window = host.window, let event = NSApp.currentEvent,
                      event.type == .leftMouseDragged else { return }
                window.performDrag(with: event)
            }
    }

    /// Shown while the mouse moves, gone three seconds after it stops.
    private func showChrome() {
        setChrome(true)
        hideChrome?.cancel()
        hideChrome = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            setChrome(false)
        }
    }

    private func setChrome(_ shown: Bool) {
        guard chromeShown != shown else { return }
        withAnimation(.easeOut(duration: 0.2)) { chromeShown = shown }
        applyChrome()
    }

    /// The traffic lights follow the rest of the chrome.
    private func applyChrome() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            host.window?.standardWindowButton(kind)?.animator().alphaValue = chromeShown ? 1 : 0
        }
    }

    /// Full-screen notifications fire for every window in the app. Compare
    /// against the actual hosting window rather than its title, which SwiftUI is
    /// free to change or localise.
    private func isThisWindow(_ note: Notification) -> Bool {
        guard let window = note.object as? NSWindow, let host = host.window else { return false }
        return window === host
    }

}

/// Keeps a window above other apps while the preference is on.
struct AlwaysOnTop: ViewModifier {
    static let defaultsKey = "alwaysOnTop"

    @AppStorage(AlwaysOnTop.defaultsKey) private var onTop = false
    @State private var host = WindowHolder()

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window in
                host.window = window
                apply()
            })
            .onChange(of: onTop) { _, _ in apply() }
    }

    private func apply() {
        host.window?.level = onTop ? .floating : .normal
    }
}

/// Holds the hosting window without participating in SwiftUI's update cycle.
private final class WindowHolder {
    weak var window: NSWindow?
}

/// Hands over the NSWindow hosting this view, to configure it and match its
/// notifications.
struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    final class Coordinator {
        weak var resolved: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window yet during makeNSView.
        DispatchQueue.main.async { resolve(view, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { resolve(view, context.coordinator) }
    }

    /// On every update, not once: SwiftUI can overwrite window configuration
    /// applied at startup. Safe because the window is held in a reference box.
    private func resolve(_ view: NSView, _ coordinator: Coordinator) {
        guard let window = view.window else { return }
        let isNew = window !== coordinator.resolved
        coordinator.resolved = window
        onResolve(window)

        if isNew {
            Diagnostics.log("window \"\(window.title)\": fullScreenPrimary=\(window.collectionBehavior.contains(.fullScreenPrimary)) resizable=\(window.styleMask.contains(.resizable))")
        }
    }
}
