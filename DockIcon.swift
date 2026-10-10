import AppKit
import SwiftUI

/// Swaps the Dock icon between the light and dark artwork.
///
/// macOS has no appearance-aware app icon outside Liquid Glass (an `.icns`
/// holds one image), so it's set at runtime: the Dock and app switcher while
/// running. The Finder, and the Dock before launch, show the `.icns` — the
/// light artwork.
@MainActor
enum DockIcon {

    private static var started = false

    /// Call from `applicationDidFinishLaunching`, not from `App.init()`:
    /// `NSApp` is still nil that early, so nothing would be applied.
    static func start() {
        guard !started else { return }
        started = true

        // A --glass build (the only one with CFBundleIconName) has the system
        // vary the icon itself.
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") == nil else {
            Diagnostics.log("dock icon: left to the system (Liquid Glass build)")
            return
        }

        apply()

        // Read on the next turn of the run loop: the notification arrives
        // before `effectiveAppearance` catches up.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { apply() } }
            }
    }

    private static func apply() {
        let app = NSApplication.shared
        let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = dark ? "StudioOneDark" : "StudioOne"
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            // No such artwork in the bundle: leave whatever Info.plist named.
            Diagnostics.log("dock icon: \(name).icns missing")
            return
        }
        app.applicationIconImage = image
        Diagnostics.log("dock icon: \(dark ? "dark" : "light")")
    }
}

/// For the hooks SwiftUI's `App` lacks: after `NSApp` exists but before the
/// first window draws, and when a quit arrives.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AutoQuitWatch.noteQuit()
        LightShow.shared.shutDown()
        Performances.shared.shutDown()
        return .terminateNow
    }
}

/// Notices another app quitting Studio One behind your back.
///
/// Utilities that quit apps once their last window closes (Vorssaint does)
/// take the Stream Deck, Logic's key and tempo, and the request line down with
/// it. A quit sent by a third-party app with no window open is remembered and
/// reported on the next launch; the Dock, logout and ⌘Q are left alone.
@MainActor
enum AutoQuitWatch {
    static let defaultsKey = "autoQuitBy"

    static func noteQuit() {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEQuitApplication) else { return }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier, !bundleID.hasPrefix("com.apple.") else { return }
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        guard !windowOpen else { return }
        let name = app.localizedName ?? bundleID
        UserDefaults.standard.set(name, forKey: defaultsKey)
        Diagnostics.log("quit: \(name) (\(bundleID)) quit Studio One with no windows open")
    }

    static var culprit: String? { UserDefaults.standard.string(forKey: defaultsKey) }
    static func dismiss() { UserDefaults.standard.removeObject(forKey: defaultsKey) }
}
