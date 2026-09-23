import Foundation
import AppKit

/// Appends timestamped diagnostics to a file, so a failure in the middle of a
/// party can be read afterwards instead of reproduced.
///
/// Deliberately cheap: one line per meaningful event — track changes, lookups,
/// connection changes, errors — never anything per frame. Credentials are never
/// written.
enum Diagnostics {

    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Studio One", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var fileURL: URL { directory.appendingPathComponent("spot-a-oke.log") }

    private static let queue = DispatchQueue(label: "com.logan.SpotifyKaraoke.diagnostics")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Marks a new run, and records the machine it's running on — this log is
    /// usually read by someone who wasn't there, so the environment has to be in
    /// the file rather than in a follow-up question.
    @MainActor
    static func startSession() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        log("──────── session started \(f.string(from: Date())) ────────")

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        log("app: Studio One \(version) (build \(build))")
        log("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let spotify = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.spotify.client")
        log("spotify installed: \(spotify?.path ?? "NO")")
        log("spotify running: \(NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty ? "no" : "yes")")

        let screens = NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.maximumFramesPerSecond)Hz" }
        log("displays: \(screens.joined(separator: ", "))")

        // Deliberately NOT reading the keychain here. A keychain read can raise
        // an authorisation prompt, and this runs on the main thread at launch —
        // it would hang the app before it draws. Whether credentials work is
        // visible anyway from the lookup results logged per track.
        let defaults = UserDefaults.standard
        log("settings: midi=\(defaults.bool(forKey: MIDIBridge.enabledKey)) clock=\(defaults.bool(forKey: MIDIBridge.clockKey)) plugin=\(PitchPlugin.current.rawValue) fps=\(defaults.object(forKey: FrameRate.defaultsKey) as? Double ?? FrameRate.minimum) onTop=\(defaults.bool(forKey: AlwaysOnTop.defaultsKey))")
    }

    static func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    /// Puts the whole log on the clipboard, ready to paste into a message.
    /// Far easier to ask for than "find this file in your Library folder".
    @discardableResult
    static func copyToClipboard() -> Bool {
        queue.sync { }   // let any pending writes land first
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        return true
    }

    /// Writes a copy to the Desktop, for attaching to an email.
    @discardableResult
    static func saveToDesktop() -> URL? {
        queue.sync { }
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let target = desktop.appendingPathComponent("Studio One log \(f.string(from: Date())).txt")
        try? text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    /// Keeps a long night from filling the disk, while retaining one previous file.
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > 2_000_000 else { return }
        let previous = directory.appendingPathComponent("previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }
}
