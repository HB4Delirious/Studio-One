import AppKit
import ApplicationServices
import QuartzCore

/// AppleScript for one player, run one script at a time and never on the main
/// thread.
///
/// NSAppleScript is not safe to use from two threads, and an Apple Event can
/// take anything from milliseconds to seconds when the player is busy. So each
/// player gets one serial queue, and every script for it — the poll, the
/// transport, the library — goes through here.
final class PlayerScripts: @unchecked Sendable {

    let bundleID: String
    private let queue: DispatchQueue

    init(bundleID: String) {
        self.bundleID = bundleID
        queue = DispatchQueue(label: "com.logan.SpotifyKaraoke.script.\(bundleID)")
    }

    var isPlayerRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// For a script run on every poll, where compiling each time would cost
    /// about 50 ms.
    static func compile(_ source: String) throws -> NSAppleScript {
        guard let script = NSAppleScript(source: source) else { throw PlayerError.malformedResponse }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        if let error { throw PlayerError(scriptError: error) }
        return script
    }

    /// Runs a compiled script. `sampledAt` is the middle of the round trip —
    /// when a reading it returns was most likely true.
    func run(_ script: NSAppleScript) async throws
        -> (result: NSAppleEventDescriptor, sampledAt: CFTimeInterval, took: TimeInterval) {
        try await perform {
            let start = CACurrentMediaTime()
            let result = try Self.execute(script)
            let end = CACurrentMediaTime()
            return (result, start + (end - start) / 2, end - start)
        }
    }

    @discardableResult
    func run(_ source: String) async throws -> NSAppleEventDescriptor {
        try await perform {
            guard let script = NSAppleScript(source: source) else { throw PlayerError.malformedResponse }
            return try Self.execute(script)
        }
    }

    func text(_ source: String) async throws -> String {
        try await run(source).stringValue ?? ""
    }

    func data(_ source: String) async throws -> Data? {
        try await run(source).data
    }

    /// `tell application … to <command>`, bounded at ten seconds instead of
    /// AppleScript's two minutes, so a player stuck behind a dialog doesn't
    /// hold up every button pressed after it.
    func tell(_ command: String) async throws {
        try await run("""
        with timeout of 10 seconds
            tell application id "\(bundleID)" to \(command)
        end timeout
        """)
    }

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.isPlayerRunning else { return continuation.resume(throwing: PlayerError.notRunning) }
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func execute(_ script: NSAppleScript) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw PlayerError(scriptError: error) }
        return result
    }

    // MARK: - Permission

    /// Whether macOS lets this app send Apple Events to `bundleID`. With
    /// `prompt`, asks the first time — and blocks until the dialog is
    /// answered, so never call it on the main thread.
    @discardableResult
    static func automationPermission(for bundleID: String, prompt: Bool) -> Bool {
        var target = AEAddressDesc()
        let created = Data(bundleID.utf8).withUnsafeBytes { buffer in
            OSStatus(AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target))
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt) == noErr
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}

extension PlayerError {
    /// From the error dictionary NSAppleScript fills in.
    init(scriptError: NSDictionary) {
        switch scriptError[NSAppleScript.errorNumber] as? Int ?? 0 {
        case -1743, -1744: self = .notAuthorized
        case -600, -609:   self = .notRunning
        case -1712:        self = .notResponding
        default:           self = .scriptFailed(scriptError[NSAppleScript.errorMessage] as? String ?? "unknown error")
        }
    }
}

extension MusicPlayer {
    func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).first?.activate()
    }
}
