import AppKit
import SwiftUI

/// Settings: a sidebar of panes. Everything applies the moment it changes
/// except the account keys, which wait for Save — they live here, with the
/// footer that saves them.
struct SettingsSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var spotify = SpotifySession.shared
    @State private var tab: Tab
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var songBPMKey = ""
    /// What the keychain held when the sheet opened, to tell an edit from none.
    @State private var stored = (clientID: "", clientSecret: "", songBPM: "")
    @State private var revealKeys = false
    /// The keys' fields, folded away once they're saved.
    @State private var editingSpotifyKeys = false
    @State private var editingSongBPMKey = false
    /// Remembered between openings, as it was last left.
    @AppStorage("settingsSheetWidth") private var savedWidth = 860.0
    @AppStorage("settingsSheetHeight") private var savedHeight = 720.0

    init(tab: Tab = .accounts) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
                .frame(maxHeight: .infinity)
                .glassPane(cornerRadius: Chrome.paneRadius - 4)
                .padding(Chrome.gutter)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch tab {
                        case .accounts:    accounts
                        case .keyAndTempo: KeyAndTempoSettings()
                        case .logic:       LogicSettings()
                        case .plugins:     PluginDisplaySettings()
                        case .mixer:       MixerSettings()
                        case .display:     DisplaySettings()
                        case .breaks:      BetweenSongsSettings()
                        case .venue:       VenueSettings()
                        case .lights:      LightsSettings()
                        case .recordings:  RecordingsSettings()
                        case .remote:      RemoteSettings()
                        case .streamDeck:  StreamDeckSettings()
                        case .rigCheck:    RigCheckPanel()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 24)
                }

                Rectangle().fill(Theme.hairline).frame(height: 1)
                // Only edited keys wait for a save; otherwise there's nothing to
                // cancel, so the footer is just Done.
                HStack {
                    if credentialsChanged {
                        Text("Your key changes aren't saved yet.")
                            .font(Theme.label)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if credentialsChanged {
                        Button("Discard") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .glassButton()
                        Button("Save Changes") { save() }
                            .keyboardShortcut(.defaultAction)
                            .glassButton(prominent: true, tint: model.palette.accent)
                    } else {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .glassButton(prominent: true, tint: model.palette.accent)
                    }
                }
                .controlSize(.large)
                .padding(.horizontal, 22).padding(.vertical, 12)
            }
        }
        // Resizable, and kept the size it was left at: Rig check runs long.
        .frame(minWidth: 820, idealWidth: savedWidth, maxWidth: 1400,
               minHeight: 560, idealHeight: savedHeight, maxHeight: .infinity)
        .background(Theme.panel)
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size) { _, size in
                savedWidth = size.width
                savedHeight = size.height
            }
        })
        // A sheet's window isn't resizable unless asked; the frame above
        // then follows it.
        .background(WindowReader { window in
            window.styleMask.insert(.resizable)
            window.minSize = NSSize(width: 820, height: 560)
        })
        .onAppear {
            clientID = Credentials.read(.clientID) ?? ""
            clientSecret = Credentials.read(.clientSecret) ?? ""
            songBPMKey = Credentials.read(.songBPM) ?? ""
            stored = (clientID, clientSecret, songBPMKey)
            editingSpotifyKeys = clientID.isEmpty || clientSecret.isEmpty
            editingSongBPMKey = songBPMKey.isEmpty
        }
    }

    private var credentialsChanged: Bool {
        clientID != stored.clientID || clientSecret != stored.clientSecret || songBPMKey != stored.songBPM
    }

    /// Which pane is showing.
    enum Tab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case keyAndTempo = "Key & tempo"
        case logic = "Logic"
        case plugins = "Plug-ins"
        case mixer = "Mixer & songs"
        case display = "Display"
        case breaks = "Between songs"
        case venue = "Venue"
        case lights = "Lights"
        case recordings = "Recordings"
        case streamDeck = "Stream Deck"
        case remote = "iPhone Remote"
        case rigCheck = "Rig check"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .accounts:    return "key.fill"
            case .keyAndTempo: return "metronome.fill"
            case .logic:       return "pianokeys"
            case .plugins:     return "switch.2"
            case .mixer:       return "slider.vertical.3"
            case .display:     return "macwindow"
            case .breaks:      return "cup.and.saucer.fill"
            case .venue:       return "building.2.fill"
            case .lights:      return "lightbulb.2.fill"
            case .recordings:  return "record.circle.fill"
            case .streamDeck:  return "dial.medium"
            case .remote:      return "iphone"
            case .rigCheck:    return "checklist"
            }
        }

        /// The icon's tile, System Settings style: each pane its own colour.
        var color: Color {
            switch self {
            case .accounts:    return .blue
            case .keyAndTempo: return .orange
            case .logic:       return .purple
            case .plugins:     return .pink
            case .mixer:       return .gray
            case .display:     return .cyan
            case .breaks:      return .teal
            case .venue:       return .brown
            case .lights:      return .yellow
            case .recordings:  return .red
            case .streamDeck:  return .indigo
            case .remote:      return .mint
            case .rigCheck:    return .green
            }
        }
    }

    /// The sidebar's groups, so the panes read as four places.
    private static let groups: [(title: String, tabs: [Tab])] = [
        ("Music", [.accounts, .keyAndTempo]),
        ("Logic", [.logic, .plugins, .mixer]),
        ("The room", [.display, .breaks, .venue, .lights, .recordings, .streamDeck, .remote]),
        ("Help", [.rigCheck]),
    ]

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)

            ForEach(Self.groups, id: \.title) { group in
                Text(group.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 3)
            ForEach(group.tabs) { entry in
                Button { tab = entry } label: {
                    HStack(spacing: 9) {
                        Image(systemName: entry.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(entry.color.gradient,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(entry.rawValue)
                            .font(.system(size: 13, weight: tab == entry ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == entry ? .white : Color.white.opacity(0.78))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: Chrome.rowRadius + 2, style: .continuous)
                        .fill(tab == entry ? model.palette.accent.opacity(0.34) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 176)
        .background(Theme.backdrop.opacity(0.45))
    }

    // MARK: - Accounts

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Accounts")

            SettingsSection("Spotify", divided: false, info: "Create an app at developer.spotify.com/dashboard and copy its client ID and secret. They're enough to search Spotify, and they're stored in your login keychain.") {
                if editingSpotifyKeys {
                    labelled("Client ID") {
                        secret($clientID)
                    }
                    labelled("Client secret") {
                        secret($clientSecret)
                    }
                } else {
                    savedKeyRow("Client ID and secret saved", button: "Change Keys…") { editingSpotifyKeys = true }
                }
                spotifySignIn
                    .padding(.top, 4)
            }

            SettingsSection("GetSongBPM", info: "Optional. Fills in key and tempo where ReccoBeats has none — see Key & tempo.") {
                if editingSongBPMKey {
                    labelled("API key") {
                        secret($songBPMKey)
                    }
                } else {
                    savedKeyRow("API key saved", button: "Change Key…") { editingSongBPMKey = true }
                }
            }

            if editingSpotifyKeys || editingSongBPMKey {
                Toggle("Show the keys", isOn: $revealKeys)
                    .font(.system(size: 12, design: .rounded))
                    .help("They stay hidden by default so this pane is safe to screen-share")
            }
        }
    }

    /// A key that's set: said so, with the way to change it.
    private func savedKeyRow(_ text: String, button: String, change: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "key.fill")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Button(button, action: change)
                .controlSize(.small)
        }
    }

    /// Optional: only needed to see your own playlists, saved songs and queue.
    private var spotifySignIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let name = spotify.name {
                    Label("Signed in as \(name)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.cue)
                    Button("Sign Out") { spotify.signOut() }
                        .controlSize(.small)
                } else {
                    Button(spotify.busy ? "Waiting for Spotify…" : "Sign In to Spotify") {
                        // The client ID must be in the keychain before the
                        // browser opens; `save()` would close the sheet.
                        Credentials.write(clientID.trimmingCharacters(in: .whitespaces), for: .clientID)
                        spotify.signIn()
                    }
                    .disabled(spotify.busy || clientID.isEmpty)
                    if spotify.busy { ProgressView().controlSize(.small) }
                }
            }
            if let error = spotify.error {
                Text(error)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Redirect URI:").font(Theme.label).foregroundStyle(Theme.secondary)
                Text(SpotifyAccount.redirectURI)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyAccount.redirectURI, forType: .string)
                }
                .controlSize(.mini)
                .help("Copy the Redirect URI")
                InfoButton("Only for your library: playlists, Liked Songs and the queue. The login happens on Spotify's page in your browser — Studio One never sees your password. Add this Redirect URI to your app in the Spotify dashboard first.")
            }
        }
    }

    /// Masked unless "Show the keys" is on: this pane gets opened while
    /// screen-sharing.
    @ViewBuilder
    private func secret(_ text: Binding<String>) -> some View {
        if revealKeys {
            TextField("", text: text)
        } else {
            SecureField("", text: text)
        }
    }

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.label)
                .foregroundStyle(Theme.secondary)
            content()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    /// Writes only what changed: rewriting a keychain item can bring its
    /// prompt back.
    private func save() {
        if clientID != stored.clientID || clientSecret != stored.clientSecret {
            Credentials.write(clientID.trimmingCharacters(in: .whitespaces), for: .clientID)
            Credentials.write(clientSecret.trimmingCharacters(in: .whitespaces), for: .clientSecret)
            Task { await SpotifyAPI.shared.resetToken() }
        }
        if songBPMKey != stored.songBPM {
            Credentials.write(songBPMKey.trimmingCharacters(in: .whitespaces), for: .songBPM)
            // Drop cached lookups so a new key takes effect on the current track.
            Task { await AnalysisProvider.shared.invalidate() }
        }
        dismiss()
    }
}
