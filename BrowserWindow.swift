import AppKit
import SwiftUI

/// The Controls window: sidebar, library, and what's playing, with the key,
/// tempo and source controls along the bottom. The library is Apple Music's,
/// or Spotify's once signed in (see `MusicBrowser`).
struct BrowserWindow: View {
    @EnvironmentObject private var model: KaraokeModel
    @StateObject private var library = LibraryModel()
    @ObservedObject private var spotify = SpotifySession.shared
    @ObservedObject private var preparation = Preparation.shared
    @ObservedObject private var display = PluginDisplay.shared
    @ObservedObject private var requests = RequestServer.shared
    @AppStorage(Self.sidebarHiddenKey) private var sidebarHidden = false
    @State private var showSettings = false
    @State private var settingsTab = SettingsSheet.Tab.accounts
    @State private var showSession = false
    @State private var showTiming = false
    @State private var showHistory = false
    @State private var autoQuitter = AutoQuitWatch.culprit
    @State private var wrongPorts: [LogicAssignments.WrongPort] = []
    @ObservedObject private var assistant = SetupAssistant.shared
    @Environment(\.openWindow) private var openWindow

    /// Across the top: another app quitting Studio One, a control surface on
    /// the wrong port, Logic's alert, a new version.
    @ViewBuilder
    private var banners: some View {
        if let autoQuitter {
            Banner(symbol: "exclamationmark.triangle.fill",
                   text: "\(autoQuitter) quit Studio One after its windows closed, stopping the Stream Deck, the key changes and the request line. Add Studio One to \(autoQuitter)'s exceptions.") {
                Button("Dismiss") {
                    AutoQuitWatch.dismiss()
                    self.autoQuitter = nil
                }
                .glassButton()
            }
        }
        ForEach(wrongPorts, id: \.surface) { wrong in
            Banner(symbol: "exclamationmark.triangle.fill", text: wrong.banner) {
                Button("Dismiss") { wrongPorts.removeAll { $0 == wrong } }
                    .glassButton()
            }
        }
        LogicAlertBanner()
        UpdateBanner()
    }

    private var assistantSheet: some View {
        SetupAssistantSheet { tab in
            settingsTab = tab
            // Once the assistant's sheet has gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSettings = true }
        }
    }

    var body: some View {
        // Panes float as glass over the cover's colours, a gutter apart.
        VStack(spacing: Chrome.gutter) {
            banners
            HStack(spacing: Chrome.gutter) {
                if !sidebarHidden {
                    Sidebar(library: library, showHistory: $showHistory)
                        .frame(width: 210)
                        .glassPane()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: Chrome.gutter) {
                    Catalogue(library: library)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Only once Logic is there to show: until then the
                    // sidebar's Logic row says how it stands.
                    if showsPluginPanel {
                        PluginDisplayPanel()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: showsPluginPanel)
                NowPlayingPanel(library: library, showTiming: $showTiming)
                    .frame(width: 336)
                    .glassPane()
            }
            .animation(.easeOut(duration: 0.25), value: sidebarHidden)
        }
        .padding(Chrome.gutter)
        .frame(minWidth: 940, minHeight: 560)
        .background(ArtworkBackdrop())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsSheet(tab: settingsTab) }
        .sheet(isPresented: $showSession) { SessionSheet() }
        .sheet(isPresented: $showTiming) { LyricsTimingSheet() }
        .sheet(isPresented: $showHistory) { SetlistSheet() }
        .sheet(item: $preparation.shown) { PrepareSheet(playlist: $0) }
        .sheet(isPresented: $assistant.shown) { assistantSheet }
        .modifier(MainToolbar(showSession: $showSession,
                              showSettings: $showSettings, settingsTab: $settingsTab))
        .onAppear {
            model.start()
            SetupAssistant.shared.showIfNew()
            Updater.shared.checkAtLaunch()
        }
        .task {
            library.attach(to: model)
            await library.loadPlaylists()
            await library.refreshUpNext()
        }
        .task { wrongPorts = await Task.detached(priority: .utility) { LogicAssignments.wrongPorts() }.value }
        // A new source is a new controller, and a different library.
        .onChange(of: model.musicSource) { _, _ in
            Task {
                library.attach(to: model)
                await library.loadPlaylists()
                await library.refreshUpNext()
            }
        }
        .onChange(of: model.track?.uri) { _, _ in
            Task {
                await library.refreshUpNext()
                await library.refreshRequestCount()
            }
        }
        // A guest's request lands in the requests playlist.
        // The list itself, not its count, which stops changing at its cap.
        .onChange(of: requests.received) { _, _ in
            Task { await library.refreshRequestCount() }
        }
        // Opened before the player: load the library once it answers.
        .onChange(of: model.connection) { _, state in
            guard state == .ready else { return }
            Task {
                await library.loadPlaylists()
                await library.refreshUpNext()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPluginSettings)) { _ in
            settingsTab = .plugins
            showSettings = true
        }
        // The Stream Deck asks for the lyrics window; only a view can open one.
        .onReceive(NotificationCenter.default.publisher(for: .showLyricsWindow)) { _ in
            openWindow(id: StudioOneApp.lyricsWindowID)
        }
        // Signing in or out of Spotify turns the library on or off underneath.
        .onChange(of: spotify.name) { _, _ in
            Task { await library.reload() }
        }
        .modifier(AlwaysOnTop())
    }

    /// Shared with the View menu's Hide Sidebar.
    static let sidebarHiddenKey = "controlsSidebarHidden"

    /// The plug-in panel, once there's something to show or say: hidden while
    /// it's off or Logic isn't connected.
    private var showsPluginPanel: Bool {
        if display.logicAlert != nil { return true }
        switch display.phase {
        case .off, .waitingForLogic: return false
        default:                     return true
        }
    }
}

/// The Controls window's toolbar: the two windows it opens, named, then
/// Settings — two glass groups on macOS 26+, one row before. The song's own
/// tools are with the song, in the Now Playing pane; History is in the
/// sidebar.
private struct MainToolbar: ViewModifier {
    @EnvironmentObject private var model: KaraokeModel
    @Environment(\.openWindow) private var openWindow
    @State private var showGames = false
    @AppStorage(BrowserWindow.sidebarHiddenKey) private var sidebarHidden = false
    @Binding var showSession: Bool
    @Binding var showSettings: Bool
    @Binding var settingsTab: SettingsSheet.Tab

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // With the title hidden there's nothing to push the buttons right
            // but a flexible space.
            content.toolbar {
                sidebarToggle
                ToolbarSpacer(.flexible)
                windows(.automatic)
                ToolbarSpacer(.fixed)
                settings(.automatic)
            }
        } else {
            content.toolbar {
                sidebarToggle
                windows(.primaryAction)
                settings(.primaryAction)
            }
        }
    }

    /// Hides the sidebar for a wider grid, as Music does (⌃⌘S).
    private var sidebarToggle: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { sidebarHidden.toggle() } label: {
                Label(sidebarHidden ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left")
            }
            .help(sidebarHidden ? "Show the sidebar (⌃⌘S)" : "Hide the sidebar (⌃⌘S)")
        }
    }

    @ToolbarContentBuilder
    private func windows(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItemGroup(placement: placement) {
            Button {
                openWindow(id: StudioOneApp.lyricsWindowID)
            } label: {
                Label("Lyrics", systemImage: "music.mic").labelStyle(.titleAndIcon)
            }
            .help("Open the lyrics display — drag it to a second screen")
            Button { showSession = true } label: {
                Label("Request Line", systemImage: "qrcode").labelStyle(.titleAndIcon)
            }
            .help("Let guests add songs by scanning a code")
            Button { showGames = true } label: {
                Label("Games", systemImage: "gamecontroller.fill").labelStyle(.titleAndIcon)
            }
            .help("Song battles, finish the lyric, name that tune")
            .popover(isPresented: $showGames, arrowEdge: .bottom) {
                GamesPopover().environmentObject(model)
            }
        }
    }

    @ToolbarContentBuilder
    private func settings(_ placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItem(placement: placement) {
            Button {
                settingsTab = .accounts
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }
    }
}

/// A notice across the top of the window, as tinted glass.
struct Banner<Accessory: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassPane(cornerRadius: Chrome.cardRadius + 2, tint: .orange.opacity(0.35))
    }
}

// MARK: - Backdrop

/// The window's colour, from the playing song's cover: the artwork blurred
/// past recognition, its palette over the top, and a scrim for legibility.
/// Drawn once per song, not per frame.
private struct ArtworkBackdrop: View {
    @EnvironmentObject private var model: KaraokeModel

    var body: some View {
        // Sized to the container explicitly: left to lay itself out,
        // `scaledToFill` in a background grows the window.
        GeometryReader { geo in
            ZStack {
                Theme.backdrop

                // Texture, not colour: blurred this far it's a pale average.
                cover
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 90)
                    .saturation(1.8)
                    .opacity(0.30)

                // The colour: three pools from the palette, not one ramp.
                ForEach(Array(pools.enumerated()), id: \.offset) { index, pool in
                    RadialGradient(colors: [pool.colour, .clear],
                                   center: pool.centre,
                                   startRadius: 0,
                                   endRadius: max(geo.size.width, geo.size.height) * pool.reach)
                }

                // So contrast doesn't depend on the cover.
                LinearGradient(colors: [Theme.backdrop.opacity(0.26),
                                        Theme.backdrop.opacity(0.58)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Flattened: it sits under a pane that redraws with the scrubber, and
        // needn't be re-blurred with it.
        .drawingGroup()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.4), value: model.palette)
    }

    private struct Pool {
        let colour: Color
        let centre: UnitPoint
        let reach: Double
    }

    /// Three corners of colour from the palette, falling back to the house
    /// colours for a track with no artwork.
    private var pools: [Pool] {
        let source = model.palette.isEmpty
            ? [Theme.violet, Theme.cue, Theme.sung]
            : model.palette.prefix(3).map(\.color)
        let places: [(UnitPoint, Double, Double)] = [
            (.topLeading, 0.95, 0.80),
            (.bottomTrailing, 0.85, 0.62),
            (UnitPoint(x: 0.82, y: 0.12), 0.7, 0.45)
        ]
        return source.enumerated().map { index, colour in
            let place = places[min(index, places.count - 1)]
            return Pool(colour: colour.opacity(place.2), centre: place.0, reach: place.1)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let local = model.localArtwork {
            Image(nsImage: local).resizable().scaledToFill()
        } else if let url = model.track?.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - Sidebar

/// Where to go, not what's there: the player, search, and three places —
/// the playlists (shown once, as covers), the guests' requests, and History —
/// with how Logic stands at the foot.
private struct Sidebar: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject var library: LibraryModel
    @Binding var showHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceSwitch()
                .padding(.horizontal, 10).padding(.top, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                TextField(model.musicSource == .spotify ? "Search Spotify" : "Search Apple Music",
                          text: $library.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { library.search() }
                    .onChange(of: library.query) { _, _ in library.search() }
                if !library.query.isEmpty {
                    Button { library.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Chrome.cardRadius - 2, style: .continuous)
                .fill(Color.white.opacity(0.08)))
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 12)

            row(icon: "square.grid.2x2.fill", title: "Playlists",
                selected: library.query.isEmpty && library.selected == nil) {
                library.clearSearch()
                library.selected = nil
            }
            if let requests = library.requestsPlaylist {
                row(icon: "person.wave.2.fill", title: "Requested Songs",
                    badge: library.requestCount,
                    selected: library.query.isEmpty && library.selected == requests) {
                    library.clearSearch()
                    Task { await library.open(requests) }
                }
            }
            row(icon: "clock.arrow.circlepath", title: "History", selected: false) {
                showHistory = true
            }

            Spacer(minLength: 0)
            LogicStatus()
                .padding(10)
        }
    }

    private func row(icon: String, title: String, badge: Int? = nil, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .white : Color.white.opacity(0.72))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Chrome.rowRadius, style: .continuous)
                    .fill(selected ? model.palette.accent.opacity(0.32) : .clear))
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }
}

/// How Logic stands, from the plug-in display: a dot and a word, in place of
/// a panel that would only say "waiting". Opens the plug-in settings.
private struct LogicStatus: View {
    @ObservedObject private var display = PluginDisplay.shared

    var body: some View {
        let (word, colour, help) = state
        Button {
            NotificationCenter.default.post(name: .showPluginSettings, object: nil)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(colour).frame(width: 7, height: 7)
                Text("Logic").font(.system(size: 12, weight: .semibold))
                Text(word).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Chrome.rowRadius, style: .continuous)
                .fill(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var state: (String, Color, String) {
        if display.logicAlert != nil {
            return ("Alert open", .orange, "Logic is waiting on an alert and ignores the key, tempo and M-BRIO until it's closed")
        }
        switch display.phase {
        case .off:
            return ("Display off", Color.white.opacity(0.3), "The plug-in display is off — Settings › Plug-ins")
        case .waitingForLogic:
            return ("Not connected", Color.white.opacity(0.3), "The plug-in panel opens by itself when Logic connects. Settings › Plug-ins has the setup.")
        case .failed:
            return ("Not showing", .orange, "The plug-in display couldn't read Logic — Settings › Plug-ins")
        case .connected, .reading, .showing:
            return ("Connected", .green, "Logic is connected; its plug-ins show under the playlists")
        }
    }
}

// MARK: - Catalogue

private struct Catalogue: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject var library: LibraryModel
    @ObservedObject private var spotify = SpotifySession.shared

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 18)]

    /// Library hits shown above the catalogue's. All 25 would push the
    /// catalogue out of sight.
    private static let libraryPreview = 6
    @State private var expanded = false

    var body: some View {
        Group {
            if !library.query.isEmpty {
                results
            } else if !library.canBrowse {
                unavailable
            } else if let playlist = library.selected {
                trackList(playlist)
            } else {
                shelf
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: library.query) { _, _ in expanded = false }
    }

    /// What the host owns and can start now, then the catalogue, which Music
    /// won't play from a script — offered to open and add instead.
    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if library.searching && library.libraryHits.isEmpty && library.catalogHits.isEmpty {
                    Text("Searching…")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 22).padding(.top, 20)
                }

                if !library.libraryHits.isEmpty {
                    heading(library.isSpotify ? "Spotify" : "In Your Library", count: library.libraryHits.count)
                    let shown = expanded ? library.libraryHits
                                         : Array(library.libraryHits.prefix(Self.libraryPreview))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, track in
                        TrackRow(number: index + 1, track: track,
                                 playing: model.track?.name == track.name,
                                 accent: model.palette.accent)
                            .padding(.horizontal, 12)
                            .onTapGesture { library.play(track) }
                    }
                    if library.libraryHits.count > Self.libraryPreview {
                        Button(expanded
                               ? "Show Fewer"
                               : "Show All \(library.libraryHits.count) in Your Library") {
                            expanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.palette.accent)
                        .padding(.horizontal, 22).padding(.top, 6)
                    }
                }

                if !library.catalogHits.isEmpty {
                    heading("Apple Music", count: library.catalogHits.count,
                            info: "Music won't start these from a script. Press Play to open one — tap the + in Music and it starts here on its own, and can be queued and requested like anything else.")
                    ForEach(library.catalogHits) { track in
                        catalogRow(track)
                    }
                }

                if !library.searching && library.libraryHits.isEmpty && library.catalogHits.isEmpty {
                    Text("Nothing found for “\(library.query)”.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 22).padding(.top, 20)
                }
            }
            .padding(.vertical, 14)
        }
    }

    private func heading(_ text: String, count: Int, info: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(text).font(.system(size: 15, weight: .semibold))
            Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if let info { InfoButton(info) }
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 6)
    }

    private func catalogRow(_ track: CatalogTrack) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: track.artworkURL) { image in
                image.resizable()
            } placeholder: {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07))
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 12.5)).lineLimit(1)
                Text(track.artist).font(.system(size: 11))
                    .foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if library.awaiting == track {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Tap + in Music").font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Button("Cancel") { library.stopWaiting() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
            } else {
                Button("Play") { library.open(track) }
                    .controlSize(.small)
                    .glassButton(prominent: true, tint: model.palette.accent)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 5)
    }

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header("Playlists", subtitle: library.loading ? "Loading…" : nil)
                if library.playlists.isEmpty, !library.loading {
                    emptyShelf
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(library.playlists) { playlist in
                        PlaylistCard(playlist: playlist, cover: library.covers[playlist.index],
                                     badge: playlist == library.requestsPlaylist ? library.requestCount : nil)
                            .onAppear { library.cover(for: playlist) }
                            .onTapGesture { Task { await library.open(playlist) } }
                            .contextMenu { PrepareMenuItem(playlist: playlist) }
                    }
                }
            }
            .padding(22)
        }
    }

    /// Why the library is empty, rather than blank space.
    /// With the player closed, one quiet line: the Now Playing pane has the
    /// button to open it. Open with nothing back, the way to try again.
    @ViewBuilder
    private var emptyShelf: some View {
        let player = model.musicSource
        if !player.isRunning {
            Text("Your playlists appear here once \(player.displayName) is open.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 2)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No playlists yet")
                    .font(.system(size: 15, weight: .semibold))
                Text(library.failure ?? "Nothing came back from \(player.displayName).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await library.reload() } }
                    .controlSize(.large)
                    .glassButton(prominent: true, tint: model.palette.accent)
            }
            .padding(18)
            .frame(maxWidth: 420, alignment: .leading)
            .glassPane(cornerRadius: Chrome.cardRadius + 4)
            .padding(.top, 6)
        }
    }

    private func trackList(_ playlist: LibraryPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { library.selected = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonBorderShape(.circle)
                .glassButton()
                .help("Back to playlists")
                Text(playlist.name).font(.system(size: 22, weight: .bold))
                if library.loading {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
                Spacer()
                Text(library.tracks.isEmpty ? "" : "\(library.tracks.count) tracks")
                    .font(Theme.label).foregroundStyle(Theme.secondary)
                PrepareButton(playlist: playlist)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)

            if library.tracks.isEmpty, !library.loading, let failure = library.failure {
                Text(failure)
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22).padding(.top, 8)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(library.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(number: index + 1, track: track,
                                 playing: track.name == model.track?.name,
                                 accent: model.palette.accent)
                            .onTapGesture { library.play(track) }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 18)
            }
        }
    }

    /// Spotify before sign-in: the way to its library. Search works without.
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 30)).foregroundStyle(Theme.secondary)
            Text("See your Spotify library here")
                .font(.system(size: 15, weight: .semibold))
            Text("Sign in once to browse your playlists and Liked Songs and see the queue.\nSearching Spotify already works — type in the search box on the left.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)

            Button {
                spotify.signIn()
            } label: {
                HStack(spacing: 6) {
                    if spotify.busy { ProgressView().controlSize(.small) }
                    Text(spotify.busy ? "Waiting for Spotify in your browser…" : "Sign In to Spotify")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .controlSize(.large)
            .glassButton(prominent: true, tint: model.palette.accent)
            .disabled(spotify.busy)
            .padding(.top, 4)

            if let error = spotify.error {
                Text(error)
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Text("One-time setup: add \(SpotifyAccount.redirectURI) as a Redirect URI\nto your app in the Spotify developer dashboard.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func header(_ title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 26, weight: .bold))
            if let subtitle {
                Text(subtitle).font(Theme.label).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
    }
}

/// Opens a playlist's preparation, and shows how it's going while it runs
/// with the sheet closed.
private struct PrepareButton: View {
    @ObservedObject private var preparation = Preparation.shared
    let playlist: LibraryPlaylist

    var body: some View {
        let mine = preparation.playlist == playlist
        Button { preparation.shown = playlist } label: {
            if mine, preparation.running, !preparation.songs.isEmpty {
                Label("Preparing \(preparation.finishedCount) of \(preparation.songs.count)",
                      systemImage: "checklist")
            } else if mine, !preparation.running, preparation.attentionCount > 0 {
                Label("\(preparation.attentionCount) to look at", systemImage: "exclamationmark.triangle.fill")
            } else if mine, !preparation.running, !preparation.songs.isEmpty,
                      preparation.finishedCount == preparation.songs.count {
                Label("Prepared", systemImage: "checkmark.circle.fill")
            } else {
                Label("Prepare", systemImage: "checklist")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .controlSize(.regular)
        .glassButton()
        .help("Look up every song's lyrics, key and tempo now, and list any that need something done")
    }
}

private struct PrepareMenuItem: View {
    let playlist: LibraryPlaylist

    var body: some View {
        Button("Prepare for Tonight…") { Preparation.shared.shown = playlist }
    }
}

private struct PlaylistCard: View {
    let playlist: LibraryPlaylist
    let cover: NSImage?
    /// The requests playlist's song count.
    var badge: Int?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let cover {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                } else {
                    // Deterministic from the name, so a playlist keeps its
                    // colours between launches and while its cover loads.
                    LinearGradient(colors: Theme.tile(for: playlist.name),
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(height: 138)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(8)
                        .help("\(badge) song\(badge == 1 ? "" : "s") requested")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Chrome.cardRadius + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Chrome.cardRadius + 2, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.22 : 0.08)))
            .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 14 : 8, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.025 : 1)

            Text(playlist.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.spring(duration: 0.25)) { hovering = inside }
        }
    }
}

private struct TrackRow: View {
    let number: Int
    let track: LibraryTrack
    let playing: Bool
    let accent: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if playing {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(accent)
                } else {
                    Text("\(number)")
                        .font(Theme.timecode).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 12.5, weight: playing ? .semibold : .regular))
                    .lineLimit(1)
                Text(track.artist).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SongMarks(name: track.name, artist: track.artist)
            Text(Self.time(track.duration))
                .font(Theme.timecode).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Chrome.rowRadius, style: .continuous)
            .fill(playing ? accent.opacity(0.2) : Color.white.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A song's difficulty and the host's note, small, beside it in a list.
private struct SongMarks: View {
    let name: String
    let artist: String

    var body: some View {
        HStack(spacing: 4) {
            if let note = SongInfo.note(name, artist) {
                Image(systemName: "note.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .help(note)
            }
            if let difficulty = SongInfo.difficulty(name, artist) {
                DifficultyChip(difficulty: difficulty, compact: true)
            }
        }
    }
}

/// The host's note on the song playing: "starts quiet", "great duet".
private struct SongNoteEditor: View {
    @EnvironmentObject private var model: KaraokeModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note on this song").font(.system(size: 13, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                .frame(height: 90)
            Text("Only you see it — beside the song in Up Next and your playlists.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { text = model.songNote ?? "" }
        .onChange(of: text) { _, new in model.setSongNote(new) }
    }
}

// MARK: - Now playing

private struct NowPlayingPanel: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject var library: LibraryModel
    @ObservedObject private var requests = RequestServer.shared
    @Binding var showTiming: Bool
    @AppStorage(StagePreview.enabledKey) private var showStage = true
    @Environment(\.openWindow) private var openWindow
    @State private var showSongSettings = false
    @State private var showNote = false

    /// The panel's width less its padding; `StagePreview` is given a width
    /// rather than measuring one.
    private static let stageWidth: CGFloat = 336 - 18 * 2

    var body: some View {
        if model.connection != .ready || model.track == nil {
            IdleCard()
        } else {
            playing
        }
    }

    private var playing: some View {
        VStack(spacing: 0) {
            if showStage {
                stagePreview
                    .padding(.top, 18).padding(.horizontal, 18)
                NowPlayingHeader(compact: true)
                    .padding(.horizontal, 18)
            } else {
                NowPlayingHeader(artworkSize: 170, compact: true)
                    .padding(.top, 18).padding(.horizontal, 18)
            }

            KeyTempoEditor()
                .padding(.horizontal, 18).padding(.bottom, 12)

            GlassGroup(spacing: 18) {
            HStack(spacing: 18) {
                transport("backward.fill", "Previous track") { model.previousTrack() }
                transport(model.isPlaying ? "pause.fill" : "play.fill",
                          model.isPlaying ? "Pause" : "Play", large: true,
                          tint: model.palette.accent) {
                    model.togglePlayback()
                }
                transport("forward.fill", "Next track") { model.nextTrack() }
            }
            }

            Scrubber().padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 14)

            if let pause = model.intermission {
                BreakControls(pause: pause)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            } else if model.fillerPlaying {
                HouseMusicControls()
                    .padding(.horizontal, 18).padding(.bottom, 12)
            } else {
                FadeControls()
                    .padding(.horizontal, 18).padding(.bottom, 10)
            }

            songTools
                .padding(.horizontal, 18).padding(.bottom, 12)

            songNoteLine
            MicMeterStrip()
                .padding(.horizontal, 18).padding(.bottom, 10)
            RecordingLine()
                .padding(.horizontal, 18).padding(.bottom, 10)
            lyricsNote

            if let status = model.status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.cue)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 18)

            HStack(spacing: 8) {
                Text("Up Next").font(.system(size: 13, weight: .semibold))
                if let name = library.upNext?.playlistName {
                    Text(name).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)

            queue
        }
    }

    /// For the host, since the room's screen only shows the song's title:
    /// why there are no lyrics to follow, and what to press.
    @ViewBuilder
    private var lyricsNote: some View {
        switch model.lyricsState {
        case .missing:
            note("No timed lyrics found; the room sees the song's title.") {
                Button("Look Again") { model.reloadLyrics() }
                    .glassButton()
                    .help("Fetch this song's lyrics again (⌘R), in case the match failed")
            }
        case .plain:
            note("Only untimed words found; they scroll on the room's screen. Time Lyrics times them.") {
                EmptyView()
            }
        default:
            EmptyView()
        }
    }

    private func note<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.badge.xmark").foregroundStyle(Theme.cue)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            action().controlSize(.small)
        }
        .padding(10)
        .glassTile(tint: Theme.cue.opacity(0.15))
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    /// What applies to this song alone: its plug-in settings and its lyrics'
    /// timing — and the lyric size, when there's no preview to carry it.
    private var songTools: some View {
        HStack(spacing: 8) {
            // Only once a per-song control exists (Settings › Mixer & songs):
            // until then it could only say so.
            if !SongControl.active.isEmpty {
                Button { showSongSettings = true } label: {
                    Label("Song Settings", systemImage: "slider.horizontal.3")
                }
                .glassButton()
                .help("Plug-in settings remembered for this song")
                .popover(isPresented: $showSongSettings, arrowEdge: .bottom) {
                    SongSettingsPopover().environmentObject(model)
                }
            }
            Button { showTiming = true } label: {
                Label("Time Lyrics", systemImage: "hand.tap")
            }
            .glassButton()
            .help("Time this song's lyrics yourself by tapping along")
            Button { showNote = true } label: {
                Image(systemName: model.songNote == nil ? "note.text.badge.plus" : "note.text")
            }
            .glassButton()
            .help(model.songNote ?? "Add a note to this song — only you see it")
            .popover(isPresented: $showNote, arrowEdge: .bottom) {
                SongNoteEditor().environmentObject(model)
            }
            Spacer(minLength: 4)
            if let difficulty = model.difficulty { DifficultyChip(difficulty: difficulty) }
            if !showStage {
                LyricSizeStepper().glassTile(cornerRadius: 12)
            }
        }
        .controlSize(.small)
    }

    /// The host's note on this song, when there is one.
    @ViewBuilder
    private var songNoteLine: some View {
        if let note = model.songNote {
            Label(note, systemImage: "note.text")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.bottom, 10)
        }
    }

    /// Opens the lyrics window — where you'd go after noticing something wrong
    /// in the thumbnail.
    private var stagePreview: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.cardRadius, style: .continuous)
        return Button {
            openWindow(id: StudioOneApp.lyricsWindowID)
        } label: {
            StagePreview(width: Self.stageWidth)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .help("Open the lyrics window")
        // Beside the button, not inside it: its clicks are its own.
        .overlay(alignment: .bottomTrailing) {
            LyricSizeStepper()
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(7)
        }
    }

    @ViewBuilder
    private var queue: some View {
        if let next = library.upNext, next.tracks.count > 1 {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // The first entry is the song playing, shown above.
                    ForEach(Array(next.tracks.dropFirst().enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(Theme.timecode).foregroundStyle(Theme.secondary)
                                .frame(width: 18, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.name).font(.system(size: 12)).lineLimit(1)
                                Text(track.artist).font(.system(size: 10.5))
                                    .foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            // Who asked for it, from the request line.
                            if let singer = requests.requester(name: track.name, artist: track.artist) {
                                Label(singer, systemImage: "person.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(Theme.cue)
                                    .lineLimit(1)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.cue.opacity(0.14)))
                                    .help("Requested by \(singer)")
                            }
                            SongMarks(name: track.name, artist: track.artist)
                            Text(TrackRow.time(track.duration))
                                .font(Theme.timecode).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 5)
                    }
                }
                .padding(.bottom, 12)
            }
        } else {
            VStack(spacing: 6) {
                Text("Nothing queued")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(library.canBrowse
                     ? "Play from a playlist and what follows appears here."
                     : "Sign in to Spotify to see what's coming up.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
        }
    }

    /// Labelled explicitly: VoiceOver reads these symbols as "Back" and
    /// "Forward", which sounds like navigation.
    private func transport(_ symbol: String, _ label: String, large: Bool = false,
                           tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 19 : 14, weight: .semibold))
                .frame(width: large ? 34 : 22, height: large ? 34 : 22)
        }
        .buttonBorderShape(.circle)
        .controlSize(large ? .extraLarge : .large)
        .glassButton(prominent: large, tint: tint)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The Now Playing pane with no song: one card saying why, and the one thing
/// to do about it — rather than a dark preview, greyed-out buttons and an
/// empty queue.
private struct IdleCard: View {
    @EnvironmentObject private var model: KaraokeModel

    var body: some View {
        let player = model.musicSource.displayName
        VStack(spacing: 14) {
            Spacer()
            switch model.connection {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Connecting to \(player)…")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            case .playerNotRunning:
                card(symbol: "music.note", title: "\(player) isn't open",
                     detail: "Open it and Studio One follows whatever plays.",
                     action: ("Open \(player)", openPlayer))
            case .permissionDenied:
                card(symbol: "lock.fill", title: "Studio One can't reach \(player)",
                     detail: "Turn on \(player) for Studio One in Privacy & Security › Automation, then reopen Studio One.",
                     action: ("Open Automation Settings", { PlayerScripts.openAutomationSettings() }))
            case .failed(let message):
                card(symbol: "exclamationmark.triangle.fill", title: "Something went wrong",
                     detail: message, action: nil)
            case .ready:
                card(symbol: "music.mic", title: "Nothing playing",
                     detail: "Pick a playlist, or press play in \(player).",
                     action: nil)
            }
            if let status = model.status {
                Text(status)
                    .font(.system(size: 11)).foregroundStyle(Theme.cue)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(symbol: String, title: String, detail: String,
                      action: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(model.palette.accent)
                .frame(width: 56, height: 56)
                .glassTile(cornerRadius: 28)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let (label, run) = action {
                Button(label, action: run)
                    .controlSize(.large)
                    .glassButton(prominent: true, tint: model.palette.accent)
                    .padding(.top, 4)
            }
        }
    }

    private func openPlayer() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: model.musicSource.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Across the top of the Controls window while Logic has an alert open, as
/// either surface sees it: Logic ignores every controller until it's closed.
private struct LogicAlertBanner: View {
    @ObservedObject private var display = PluginDisplay.shared
    @ObservedObject private var check = PluginDisplay.check

    var body: some View {
        if let alert = display.logicAlert ?? check.logicAlert {
            Banner(symbol: "exclamationmark.bubble.fill",
                   text: "Logic is waiting on an alert, and ignores the key, tempo and M-BRIO until it's closed: “\(alert)”") {
                EmptyView()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Ending the song early, gently, and the time limit that will (see
/// `FadeOut`): when this song fades, with a way to let it play to the end.
private struct FadeControls: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(FadeOut.limitKey) private var limit = 0.0

    var body: some View {
        HStack(spacing: 8) {
            if model.fading {
                Label("Fading out…", systemImage: "speaker.wave.1.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.palette.accent)
                Spacer(minLength: 4)
                Button("Cancel") { model.stopFade() }
                    .glassButton()
                    .help("Stop the fade and put the volume back")
            } else {
                Button { model.fadeOut() } label: {
                    Label("Fade Out", systemImage: "speaker.wave.1.fill")
                }
                .glassButton()
                .disabled(!model.isPlaying)
                .help("Fade this song out, then on to the break or the next song (⌥⌘→)")
                Spacer(minLength: 4)
                if limit > 0, model.timeLimitApplies {
                    Text("Fades at \(FadeOut.limitTitle(limit))")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                    Button("Let It Play") { model.letItPlay() }
                        .glassButton()
                        .help("Play this song to the end, past the time limit")
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// House music playing to an empty queue: said so, with the way back.
private struct HouseMusicControls: View {
    @EnvironmentObject private var model: KaraokeModel

    var body: some View {
        HStack(spacing: 8) {
            Label("House music", systemImage: "music.note.house.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.palette.accent)
            Text(model.nextUp.map { "· then \($0.name)" } ?? "· until a request")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(model.nextUp == nil ? "Stop" : "Back to the Queue") { model.endHouseMusic() }
                .glassButton()
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassTile(tint: model.palette.accent.opacity(0.18))
    }
}

/// The break between songs, from the Controls window: how long is left, and
/// a way to start the next song now or hold it a little longer.
private struct BreakControls: View {
    @EnvironmentObject private var model: KaraokeModel
    let pause: Intermission

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Image(systemName: "cup.and.saucer.fill").foregroundStyle(model.palette.accent)
                    Text(status(at: context.date))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                Button("Start Next Song") { model.endIntermission() }
                    .glassButton(prominent: true, tint: model.palette.accent)
                if pause.endsAt != nil {
                    Button("+30 s") { model.extendIntermission() }
                        .glassButton()
                        .help("Hold the next song a little longer")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassTile(tint: model.palette.accent.opacity(0.25))
    }

    private func status(at now: Date) -> String {
        guard let endsAt = pause.endsAt else { return "Break — waiting for Play" }
        let left = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        return "Break — next song in \(left / 60):\(String(format: "%02d", left % 60))"
    }
}
