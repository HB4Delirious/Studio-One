import AppKit

/// Copies of Logic's controller assignments.
///
/// Logic keeps every learned assignment — the key, the MetaTune switches, the
/// mixer dials, the song controls — in one file, and writes it when it quits.
/// A reset or a new Mac loses them all, and relearning is dozens of steps.
/// A copy is taken automatically whenever Studio One starts and the file has
/// changed since the last one; the newest thirty are kept.
enum LogicBackup {

    static let source = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.logic.pro.cs")

    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio One/Logic backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let logicBundleID = "com.apple.logic10"
    private static let keep = 30

    static var logicIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: logicBundleID).isEmpty
    }

    static var sourceExists: Bool { FileManager.default.fileExists(atPath: source.path) }

    /// Newest first.
    static func backups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "cs" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// Copies the file now. Nil on success, or why not.
    @discardableResult
    static func backUp(note: String = "") -> String? {
        guard sourceExists else { return "Logic's assignments file isn't on this Mac." }
        let name = "Controller assignments \(stamp.string(from: Date()))\(note.isEmpty ? "" : " \(note)").cs"
        do {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
        } catch {
            return "Couldn't copy it: \(error.localizedDescription)"
        }
        prune()
        Diagnostics.log("logic: assignments backed up\(note.isEmpty ? "" : " (\(note))")")
        return nil
    }

    /// At launch: a copy only if the file differs from the newest one.
    static func backUpIfChanged() {
        guard sourceExists, let current = try? Data(contentsOf: source) else { return }
        if let newest = backups().first, let previous = try? Data(contentsOf: newest), previous == current {
            return
        }
        backUp(note: "(automatic)")
    }

    /// Puts a copy back. Logic must be closed — it writes the file as it
    /// quits, and would put its own back over this one. What was there is
    /// kept first, so a restore can itself be undone.
    static func restore(_ backup: URL) -> String? {
        guard !logicIsRunning else { return "Quit Logic first — it saves its own assignments as it quits and would undo this." }
        if sourceExists { backUp(note: "(before restoring)") }
        do {
            if sourceExists { try FileManager.default.removeItem(at: source) }
            try FileManager.default.copyItem(at: backup, to: source)
        } catch {
            return "Couldn't restore it: \(error.localizedDescription)"
        }
        Diagnostics.log("logic: assignments restored from \(backup.lastPathComponent)")
        return nil
    }

    private static func prune() {
        for old in backups().dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    static func label(for backup: URL) -> String {
        backup.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "Controller assignments ", with: "")
    }
}
