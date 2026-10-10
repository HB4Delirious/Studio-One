import AppKit
import Security
import SwiftUI

/// Updates from the project's GitHub releases. Once a day at launch (and from
/// Studio One › Check for Updates…) it asks GitHub for the latest release; a
/// newer version with a DMG gets a banner in the Controls window. Installing
/// downloads the DMG, checks the app inside is signed by the same certificate
/// as this one — the only proof, without notarization, that it's the same
/// developer's — puts it beside this copy, and swaps the two once this one
/// has quit.
///
/// The repository is `StudioOneUpdateRepo` in Info.plist ("owner/name"), or
/// the one typed in Settings › Rig check; with neither, it does nothing.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let autoKey = "checkForUpdates"
    static let lastCheckKey = "updateLastCheck"
    static let skippedKey = "updateSkipped"
    static let repoKey = "updateRepo"

    struct Release: Equatable {
        let version: String
        let notes: String
        let dmg: URL
        let page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
        case installFailed(String)
    }

    @Published private(set) var state: State = .idle
    /// The banner, put away until the next launch.
    @Published var dismissed = false

    static var automatic: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }

    static var repo: String? {
        let typed = UserDefaults.standard.string(forKey: repoKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        let built = Bundle.main.object(forInfoDictionaryKey: "StudioOneUpdateRepo") as? String ?? ""
        let repo = typed.isEmpty ? built : typed
        return isRepo(repo) ? repo : nil
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Checking

    /// At most once a day, unless turned off.
    func checkAtLaunch() {
        guard Self.automatic, Self.repo != nil else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task { await check(manually: false) }
    }

    /// `manually`: from the menu or Settings, so a skipped version is offered
    /// again and the answer is said, whatever it is.
    func check(manually: Bool) async {
        guard let repo = Self.repo else {
            state = .failed("No GitHub repository is set for updates.")
            return
        }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Studio One/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                state = .failed(status == 404 ? "\(repo) has no releases yet." : "GitHub answered \(status).")
                return
            }
            guard let release = Self.release(from: data) else {
                state = .failed("The latest release has no DMG to install.")
                return
            }
            let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
            if Self.isNewer(release.version, than: Self.currentVersion), manually || skipped != release.version {
                state = .available(release)
                dismissed = false
                Diagnostics.log("updates: \(release.version) available")
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Studio One › Check for Updates…: a newer version shows its banner;
    /// otherwise an alert says why not.
    func checkFromMenu() async {
        await check(manually: true)
        let alert = NSAlert()
        switch state {
        case .available:
            return
        case .upToDate:
            alert.messageText = "Studio One \(Self.currentVersion) is the latest version."
        case .failed(let message):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message + (Self.repo == nil ? " Set one in Settings › Rig check › Updates." : "")
        default:
            return
        }
        alert.runModal()
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        state = .idle
    }

    var statusText: String {
        switch state {
        case .idle:                    return Self.repo == nil ? "No repository set." : "Not checked since launch."
        case .checking:                return "Checking…"
        case .upToDate:                return "Studio One \(Self.currentVersion) is the latest."
        case .available(let release):  return "\(release.version) is available."
        case .installing(let step):    return step
        case .failed(let message),
             .installFailed(let message): return message
        }
    }

    // MARK: - Installing

    func install(_ release: Release) async {
        let running = Bundle.main.bundleURL
        let folder = running.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            state = .installFailed("Studio One can't write to \(folder.path) — install \(release.version) from its DMG yourself.")
            return
        }
        do {
            state = .installing("Downloading \(release.version)…")
            let (download, _) = try await URLSession.shared.download(from: release.dmg)
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Studio One/Updates", isDirectory: true)
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            let dmg = caches.appendingPathComponent("Studio One \(release.version).dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: download, to: dmg)

            state = .installing("Checking \(release.version)…")
            let staged = try await Task.detached(priority: .userInitiated) {
                try Self.stage(dmg: dmg, beside: running)
            }.value
            Diagnostics.log("updates: \(release.version) staged at \(staged.path)")

            let script = caches.appendingPathComponent("install.sh")
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), running.path, staged.path]
            try process.run()
            state = .installing("Relaunching…")
            NSApp.terminate(nil)
        } catch {
            state = .installFailed((error as? UpdateError)?.message ?? error.localizedDescription)
            Diagnostics.log("updates: install failed: \((error as? UpdateError)?.message ?? error.localizedDescription)")
        }
    }

    struct UpdateError: Error {
        let message: String
    }

    /// Mounts the DMG, finds the app, holds it to this one's signature and
    /// identity, and copies it beside `running` as a hidden staging copy.
    nonisolated static func stage(dmg: URL, beside running: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("StudioOneUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            try? FileManager.default.removeItem(at: mount)
        }
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet",
                                       "-mountpoint", mount.path, dmg.path]) == 0 else {
            throw UpdateError(message: "The DMG wouldn't open.")
        }
        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let candidate = apps.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError(message: "The DMG has no app in it.")
        }
        guard Bundle(url: candidate)?.bundleIdentifier == Bundle(url: running)?.bundleIdentifier else {
            throw UpdateError(message: "The DMG holds a different app.")
        }
        guard signedAlike(candidate, running) else {
            throw UpdateError(message: "The new version isn't signed by the same certificate as this one, so it wasn't installed. Install it from its DMG yourself if you trust it.")
        }
        let staged = running.deletingLastPathComponent().appendingPathComponent(".\(running.lastPathComponent).update")
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [candidate.path, staged.path]) == 0 else {
            throw UpdateError(message: "Couldn't copy the new version beside this one.")
        }
        return staged
    }

    /// The candidate passes a strict check of its whole signature and meets
    /// the running app's designated requirement: same identifier, same
    /// certificate. An ad-hoc signed copy can't be matched, so it's refused.
    nonisolated static func signedAlike(_ candidate: URL, _ running: URL) -> Bool {
        var ours: SecStaticCode?
        var theirs: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(running as CFURL, [], &ours) == errSecSuccess, let ours,
              SecCodeCopyDesignatedRequirement(ours, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &theirs) == errSecSuccess, let theirs else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(theirs, flags, requirement) == errSecSuccess
    }

    /// Waits for Studio One to quit, swaps in the new copy — putting the old
    /// one back if the swap fails — and opens whichever is there.
    nonisolated static let installScript = """
        #!/bin/sh
        pid="$1"; app="$2"; staged="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$app.old"
        if mv "$app" "$app.old"; then
            if mv "$staged" "$app"; then
                rm -rf "$app.old"
            else
                mv "$app.old" "$app"
            fi
        fi
        open "$app"

        """

    // MARK: - Parsing

    /// GitHub's latest release: its version from the tag ("v2.1" → "2.1"),
    /// the notes, and the first DMG among its files.
    nonisolated static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let url = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)),
              url.scheme == "https" else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", dmg: url, page: page)
    }

    /// Numerically, part by part: 2.10 is newer than 2.9, 2.0.1 than 2.0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func isRepo(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// The Controls window's banner for a new version, and for an install under
/// way or one that failed.
struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if !updater.dismissed {
            switch updater.state {
            case .available(let release):
                Banner(symbol: "arrow.down.circle.fill",
                       text: "Studio One \(release.version) is available — you have \(Updater.currentVersion). Installing quits and reopens Studio One, so it's best between nights.") {
                    HStack(spacing: 6) {
                        Button("What's New") { NSWorkspace.shared.open(release.page) }
                        Button("Install and Relaunch") { Task { await updater.install(release) } }
                        Button("Skip") { updater.skip(release) }
                        Button("Later") { updater.dismissed = true }
                    }
                    .glassButton()
                }
            case .installing(let step):
                Banner(symbol: "arrow.down.circle.fill", text: step) { ProgressView().controlSize(.small) }
            case .installFailed(let message):
                Banner(symbol: "exclamationmark.triangle.fill", text: message) {
                    Button("Dismiss") { updater.dismissed = true }.glassButton()
                }
            default:
                EmptyView()
            }
        }
    }
}

/// Settings › Rig check › Updates: the version, the repository, automatic
/// checks and Check Now.
struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Updater.autoKey) private var automatic = true
    @AppStorage(Updater.repoKey) private var typedRepo = ""

    var body: some View {
        SettingsSection("Updates", info: "Studio One checks the project's GitHub releases once a day, when it opens. A newer version shows a banner in the Controls window; installing downloads its DMG, makes sure it's signed by the same certificate as this copy, swaps it in and reopens Studio One. Studio One isn't notarized, so this signature check is what keeps an update from being anyone else's. The repository is built in; type another here only if you publish your own builds.") {
            LabelledRow("Version:") {
                Text(Updater.currentVersion).font(Theme.timecode)
                Button("Check Now") { Task { await updater.check(manually: true) } }
                    .controlSize(.small)
                    .disabled(Updater.repo == nil || updater.state == .checking)
            }
            LabelledRow("Repository:") {
                TextField(Bundle.main.object(forInfoDictionaryKey: "StudioOneUpdateRepo") as? String ?? "owner/name",
                          text: $typedRepo)
                    .frame(width: 220)
                if !typedRepo.isEmpty, !Updater.isRepo(typedRepo) {
                    Text("owner/name").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Toggle("Check for updates automatically", isOn: $automatic)
                .font(.system(size: 12, design: .rounded))
            StatusLine(updater.statusText)
        }
    }
}
