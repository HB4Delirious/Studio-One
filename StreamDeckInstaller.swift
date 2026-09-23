import AppKit

/// Hands the bundled Stream Deck plug-in to the Stream Deck app.
///
/// The plug-in is built with the app and carried in its Resources. Opening a
/// .streamDeckPlugin is how Elgato installs one, so this only finds the file,
/// checks that the Stream Deck app is what would open it — rather than letting
/// an unzip tool scatter it into Downloads — and opens it.
enum StreamDeckInstaller {

    static let fileName = "com.logan.studioone.streamDeckPlugin"

    /// Nil when the Stream Deck app took it, or why not.
    @MainActor
    static func install() -> String? {
        guard let bundled = Bundle.main.url(forResource: "com.logan.studioone",
                                            withExtension: "streamDeckPlugin") else {
            return "This build doesn't include the plug-in. Rebuild with ./build.sh."
        }
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: bundled),
              handler.lastPathComponent.localizedCaseInsensitiveContains("Stream Deck") else {
            return "The Stream Deck app isn't installed on this Mac. Install it from elgato.com (version 6.4 or later), then try again."
        }
        // A copy outside the app bundle: the original stays untouched however
        // the Stream Deck app handles the file it is given.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: bundled, to: copy)
        } catch {
            return "Couldn't prepare the plug-in: \(error.localizedDescription)"
        }
        NSWorkspace.shared.open(copy)
        Diagnostics.log("stream deck: plug-in handed to \(handler.lastPathComponent)")
        return nil
    }

    /// The ready-made Stream Deck + page. Kept apart from the plug-in so a
    /// page the app dislikes can't get in the way of the plug-in installing.
    @MainActor
    static func installPage() -> String? {
        guard let bundled = Bundle.main.url(forResource: "Studio One", withExtension: "streamDeckProfile") else {
            return "This build doesn't include the page. Rebuild with ./build.sh."
        }
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: bundled),
              handler.lastPathComponent.localizedCaseInsensitiveContains("Stream Deck") else {
            return "The Stream Deck app isn't installed on this Mac."
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Studio One.streamDeckProfile")
        try? FileManager.default.removeItem(at: copy)
        do { try FileManager.default.copyItem(at: bundled, to: copy) } catch {
            return "Couldn't prepare the page: \(error.localizedDescription)"
        }
        NSWorkspace.shared.open(copy)
        Diagnostics.log("stream deck: page handed to \(handler.lastPathComponent)")
        return nil
    }
}
