import AppKit
import SwiftUI

/// Swaps the Dock icon between the light and dark artwork.
///
/// macOS has no appearance-aware app icon. An `.icns` holds exactly one image,
/// and the asset-catalog route means Liquid Glass, which renders the icon its
/// own way — measured: `is-glass: false` is ignored, and the appearance
/// specializations compile but change nothing. Setting the icon at runtime is
/// the only mechanism that follows the system theme.
///
/// What this covers: the Dock icon and the app switcher, while the app runs.
/// What it can't: the Finder icon, and the Dock icon before launch. Those come
/// from the `.icns` named in Info.plist, which is always the light artwork.
@MainActor
enum DockIcon {

    private static var started = false

    /// Call from `applicationDidFinishLaunching`, not from `App.init()`:
    /// `NSApp` is still nil that early, so nothing would be applied.
    static func start() {
        guard !started else { return }
        started = true

        // In a --glass build the system renders the icon from Assets.car and
        // already varies it by appearance. Overriding it here would swap Liquid
        // Glass for a flat bitmap, which is the opposite of what that build is
        // for. CFBundleIconName is only present in that build.
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") == nil else {
            Diagnostics.log("dock icon: left to the system (Liquid Glass build)")
            return
        }

        apply()

        // The theme notification arrives before `effectiveAppearance` catches
        // up, so read it on the next turn of the run loop rather than now.
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

/// Exists only so there is an `applicationDidFinishLaunching` to hang the Dock
/// icon off. SwiftUI's `App` has no equivalent hook that runs after `NSApp`
/// exists but before the first window is drawn.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AutoQuitWatch.noteQuit()
        return .terminateNow
    }
}

/// Notices another app quitting Studio One behind your back.
///
/// Utilities that quit apps once their last window closes — Vorssaint was
/// caught doing it on this rig — take the Stream Deck, the key and tempo for
/// Logic and the request line down with Studio One, none of which need a
/// window. A quit sent by a third-party app while no window was open is
/// remembered, and the Controls window says so on the next launch. Quits from
/// the Dock, a logout or ⌘Q are Apple's or the app's own and are left alone.
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
