import AppKit
import SwiftUI

/// The controls window: a library browser with the player on the right.
///
/// Laid out as sidebar / catalogue / now-playing, with the existing control bar
/// kept as a full-width footer so the key, tempo and source controls stay where
/// they were.
///
/// Only Apple Music fills the middle. Spotify's scripting dictionary has no
/// library, playlists or queue at all, so on that source the catalogue explains
/// itself and search stays the way in.
struct BrowserWindow: View {
    @EnvironmentObject private var model: KaraokeModel
    @StateObject private var library = LibraryModel()
    @ObservedObject private var spotify = SpotifySession.shared
    @AppStorage("lyricFontSize") private var fontSize: Double = 42
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var showSession = false
    @State private var showTiming = false
    @State private var showSongSettings = false
    @State private var showHistory = false
    @State private var autoQuitter = AutoQuitWatch.culprit
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if let autoQuitter {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Last time, \(autoQuitter) quit Studio One after its windows closed — which also stops the Stream Deck, the key changes to Logic and the request line. Add Studio One to \(autoQuitter)'s exceptions to keep it running.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") {
                        AutoQuitWatch.dismiss()
                        self.autoQuitter = nil
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.orange.opacity(0.14))
            }
            HStack(spacing: 0) {
                Sidebar(library: library, showSearch: $showSearch)
                    .frame(width: 214)
                divider
                Catalogue(library: library)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                divider
                NowPlayingPanel(library: library)
                    .frame(width: 336)
            }
            Divider().overlay(Theme.hairline)
            ControlBar(fontSize: $fontSize, showSearch: $showSearch)
        }
        .frame(minWidth: 940, minHeight: 560)
        .background(ArtworkBackdrop())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSearch) { SearchSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showSession) { SessionSheet() }
        .sheet(isPresented: $showTiming) { LyricsTimingSheet() }
        .sheet(isPresented: $showHistory) { SetlistSheet() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showHistory = true } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .help("What was sung, night by night")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSongSettings = true } label: {
                    Label("Song settings", systemImage: "slider.horizontal.3")
                }
                .help("Plug-in settings remembered for this song")
                .popover(isPresented: $showSongSettings, arrowEdge: .bottom) {
                    SongSettingsPopover().environmentObject(model)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showTiming = true } label: {
                    Label("Time lyrics", systemImage: "hand.tap")
                }
                .help("Time this song's lyrics yourself by tapping along")
                .disabled(model.track == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: SpotifyKaraokeApp.lyricsWindowID)
                } label: { Label("Lyrics", systemImage: "music.mic") }
                .help("Open the lyrics display — drag it to a second screen")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSession = true } label: {
                    Label("Request line", systemImage: "qrcode")
                }
                .help("Let guests add songs by scanning a code")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onAppear { model.start() }
        .task {
            library.attach(to: model)
            await library.loadPlaylists()
            await library.refreshUpNext()
        }
        // The source switch rebuilds the controller underneath, so the whole
        // library belongs to the old one and has to go.
        .onChange(of: model.musicSource) { _, _ in
            Task {
                library.attach(to: model)
                await library.loadPlaylists()
                await library.refreshUpNext()
            }
        }
        .onChange(of: model.track?.uri) { _, _ in
            Task { await library.refreshUpNext() }
        }
        // Launched before the player: the first load found nothing to ask and
        // the library stayed empty for the session. Load once it answers.
        .onChange(of: model.connection) { _, state in
            guard state == .ready else { return }
            Task {
                await library.loadPlaylists()
                await library.refreshUpNext()
            }
        }
        // The Stream Deck asks for the lyrics window through the control port;
        // opening a window has to happen here, in a view.
        .onReceive(NotificationCenter.default.publisher(for: .showLyricsWindow)) { _ in
            openWindow(id: SpotifyKaraokeApp.lyricsWindowID)
        }
        // Signing in or out of Spotify turns the library on or off underneath.
        .onChange(of: spotify.name) { _, _ in
            Task { await library.reload() }
        }
        .modifier(AlwaysOnTop())
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1)
    }
}

// MARK: - Backdrop

/// The window's colour, taken from the cover of whatever is playing.
///
/// The artwork itself, blurred well past recognition, with the palette already
/// extracted from it laid over the top and a scrim beneath the content to keep
/// text readable. It only redraws when the track changes, so the blur is paid
/// for once rather than per frame.
private struct ArtworkBackdrop: View {
    @EnvironmentObject private var model: KaraokeModel

    var body: some View {
        // The cover is sized to the container explicitly rather than allowed to
        // lay itself out. `scaledToFill` inside a background once inflated this
        // window until the controls were pushed off the bottom of the screen.
        GeometryReader { geo in
            ZStack {
                Theme.backdrop

                // The cover is texture, not colour. Blurred this far it is
                // mostly a pale average — pushing colour through it with a
                // lighten blend just greyed the whole window out.
                cover
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 90)
                    .saturation(1.8)
                    .opacity(0.30)

                // The colour comes from the palette the cover produced. Three
                // pools rather than one ramp, so it reads like the app's own
                // background rather than a flat gradient.
                ForEach(Array(pools.enumerated()), id: \.offset) { index, pool in
                    RadialGradient(colors: [pool.colour, .clear],
                                   center: pool.centre,
                                   startRadius: 0,
                                   endRadius: max(geo.size.width, geo.size.height) * pool.reach)
                }

                // Everything above sits on this, so contrast doesn't depend on
                // which cover happens to be playing.
                LinearGradient(colors: [Theme.backdrop.opacity(0.26),
                                        Theme.backdrop.opacity(0.58)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Flattened to one texture. The content only changes when the track
        // does, but it sits under a pane that redraws with the scrubber, and
        // re-blurring a full-window image at 30fps for nothing is exactly the
        // kind of waste the frame-rate work went after.
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

private struct Sidebar: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject var library: LibraryModel
    @Binding var showSearch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                TextField(model.musicSource == .spotify ? "Search Spotify" : "Search Apple Music",
                          text: $library.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { library.search() }
                    .onChange(of: library.query) { _, _ in library.search() }
                if !library.query.isEmpty {
                    Button { library.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 14)

            row(icon: "square.grid.2x2.fill", title: "Playlists",
                selected: library.selected == nil) {
                library.selected = nil
            }

            if !library.playlists.isEmpty {
                Text("MY PLAYLISTS")
                    .font(Theme.label).foregroundStyle(Theme.upcoming)
                    .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(library.playlists) { playlist in
                            row(icon: "music.note.list", title: playlist.name,
                                selected: library.selected == playlist) {
                                Task { await library.open(playlist) }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .background(Theme.backdrop.opacity(0.38))
    }

    private func row(icon: String, title: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 15)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .white : Color.white.opacity(0.62))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? model.palette.accent.opacity(0.28) : .clear))
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Catalogue

private struct Catalogue: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject var library: LibraryModel
    @ObservedObject private var spotify = SpotifySession.shared

    private let columns = [GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 18)]

    /// Library hits shown before the "Apple Music" heading. The library search
    /// returns up to 25, which is three screens — enough to hide the catalogue
    /// results completely and make the search look like it never left the
    /// library at all. Six fits above the fold with room to spare.
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

    /// Two lists: what the host owns and can start now, then the rest of the
    /// catalogue, which Music will not play from a script and so is offered as
    /// somewhere to go and add.
    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if library.searching && library.libraryHits.isEmpty && library.catalogHits.isEmpty {
                    Text("Searching…")
                        .font(.system(size: 12)).foregroundStyle(Theme.upcoming)
                        .padding(.horizontal, 22).padding(.top, 20)
                }

                if !library.libraryHits.isEmpty {
                    heading(library.isSpotify ? "SPOTIFY" : "IN YOUR LIBRARY", count: library.libraryHits.count)
                    let shown = expanded ? library.libraryHits
                                         : Array(library.libraryHits.prefix(Self.libraryPreview))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, track in
                        TrackRow(number: index + 1, track: track,
                                 playing: model.track?.name == track.name,
                                 accent: model.palette.accent)
                            .padding(.horizontal, 12)
                            .onTapGesture { library.playHit(track) }
                    }
                    if library.libraryHits.count > Self.libraryPreview {
                        Button(expanded
                               ? "Show fewer"
                               : "Show all \(library.libraryHits.count) in your library") {
                            expanded.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.palette.accent)
                        .padding(.horizontal, 22).padding(.top, 6)
                    }
                }

                if !library.catalogHits.isEmpty {
                    heading("APPLE MUSIC", count: library.catalogHits.count)
                    Text("Music won't start these from a script. Press Play to open one — tap the + in Music and it starts here on its own, and can be queued and requested like anything else.")
                        .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                        .padding(.horizontal, 22).padding(.bottom, 8)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(library.catalogHits) { track in
                        catalogRow(track)
                    }
                }

                if !library.searching && library.libraryHits.isEmpty && library.catalogHits.isEmpty {
                    Text("Nothing found for “\(library.query)”.")
                        .font(.system(size: 12)).foregroundStyle(Theme.upcoming)
                        .padding(.horizontal, 22).padding(.top, 20)
                }
            }
            .padding(.vertical, 14)
        }
    }

    private func heading(_ text: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(text).font(Theme.label).foregroundStyle(model.palette.accent)
            Text("\(count)").font(Theme.label).foregroundStyle(Theme.upcoming)
        }
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 6)
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
                    .foregroundStyle(Theme.upcoming).lineLimit(1)
            }
            Spacer(minLength: 6)
            if library.awaiting == track {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Tap + in Music").font(.system(size: 11))
                        .foregroundStyle(Theme.upcoming)
                    Button("Cancel") { library.stopWaiting() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.upcoming)
                }
            } else {
                Button("Play") { library.open(track) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(model.palette.accent.opacity(0.34)))
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
                        PlaylistCard(playlist: playlist, cover: library.covers[playlist.index])
                            .onAppear { library.cover(for: playlist) }
                            .onTapGesture { Task { await library.open(playlist) } }
                    }
                }
            }
            .padding(22)
        }
    }

    /// Said out loud rather than left blank: the grid used to be an empty
    /// space whenever the player was closed, with the reason held back.
    private var emptyShelf: some View {
        let player = model.musicSource
        let closed = !player.isRunning
        return VStack(alignment: .leading, spacing: 10) {
            Text(closed ? "\(player.displayName) isn't open" : "No playlists yet")
                .font(.system(size: 15, weight: .semibold))
            Text(closed
                 ? "Your playlists appear here as soon as it is."
                 : (library.failure ?? "Nothing came back from \(player.displayName)."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.upcoming)
                .fixedSize(horizontal: false, vertical: true)
            Button(closed ? "Open \(player.displayName)" : "Try again") {
                if closed {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                } else {
                    Task { await library.reload() }
                }
            }
            .controlSize(.regular)
        }
        .padding(.top, 6)
    }

    private func trackList(_ playlist: LibraryPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { library.selected = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)
                Text(playlist.name).font(.system(size: 19, weight: .semibold))
                if library.loading {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
                Spacer()
                Text(library.tracks.isEmpty ? "" : "\(library.tracks.count) tracks")
                    .font(Theme.label).foregroundStyle(Theme.upcoming)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)

            if library.tracks.isEmpty, !library.loading, let failure = library.failure {
                Text(failure)
                    .font(.system(size: 12)).foregroundStyle(Theme.upcoming)
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

    /// Spotify before sign-in. The desktop app's scripting has no library, so
    /// this is the way to one — and search already works without it.
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 30)).foregroundStyle(Theme.upcoming)
            Text("See your Spotify library here")
                .font(.system(size: 15, weight: .semibold))
            Text("Sign in once to browse your playlists and Liked Songs and see the queue.\nSearching Spotify already works — type in the search box on the left.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.upcoming)
                .multilineTextAlignment(.center)

            Button {
                spotify.signIn()
            } label: {
                HStack(spacing: 6) {
                    if spotify.busy { ProgressView().controlSize(.small) }
                    Text(spotify.busy ? "Waiting for Spotify in your browser…" : "Sign in to Spotify")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Capsule().fill(model.palette.accent.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(spotify.busy)
            .padding(.top, 4)

            if let error = spotify.error {
                Text(error)
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Text("One-time setup: add \(SpotifyAccount.redirectURI) as a Redirect URI\nto your app in the Spotify developer dashboard.")
                .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func header(_ title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 19, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(Theme.label).foregroundStyle(Theme.upcoming)
            }
            Spacer()
        }
    }
}

private struct PlaylistCard: View {
    let playlist: LibraryPlaylist
    let cover: NSImage?

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
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))

            Text(playlist.name)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

private struct TrackRow: View {
    let number: Int
    let track: LibraryTrack
    let playing: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if playing {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(accent)
                } else {
                    Text("\(number)")
                        .font(Theme.timecode).foregroundStyle(Theme.upcoming)
                }
            }
            .frame(width: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name).font(.system(size: 12.5, weight: playing ? .semibold : .regular))
                    .lineLimit(1)
                Text(track.artist).font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Self.time(track.duration))
                .font(Theme.timecode).foregroundStyle(Theme.upcoming)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(playing ? accent.opacity(0.16) : .clear))
        .contentShape(Rectangle())
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Now playing

private struct NowPlayingPanel: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject var library: LibraryModel
    @AppStorage(StagePreview.enabledKey) private var showStage = true
    @Environment(\.openWindow) private var openWindow

    /// The panel's own width less its padding — `StagePreview` scales to a width
    /// it is given rather than measuring, so the number lives here next to the
    /// padding it is derived from.
    private static let stageWidth: CGFloat = 336 - 18 * 2

    var body: some View {
        VStack(spacing: 0) {
            if showStage {
                stagePreview
                    .padding(.top, 18).padding(.horizontal, 18)
                NowPlayingHeader(centred: true, showArtwork: false)
                    .padding(.horizontal, 18)
            } else {
                NowPlayingHeader(artworkSize: 190, centred: true)
                    .padding(.top, 22).padding(.horizontal, 18)
            }

            HStack(spacing: 22) {
                transport("backward.fill", "Previous track") { model.previousTrack() }
                transport(model.isPlaying ? "pause.fill" : "play.fill",
                          model.isPlaying ? "Pause" : "Play", large: true,
                          tint: model.palette.accent) {
                    model.togglePlayback()
                }
                transport("forward.fill", "Next track") { model.nextTrack() }
            }
            .padding(.top, 16)

            Scrubber().padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 16)

            Divider().overlay(Theme.hairline)

            HStack(spacing: 8) {
                Text("QUEUE").font(Theme.label).foregroundStyle(model.palette.accent)
                if let name = library.upNext?.playlistName {
                    Text(name).font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)

            queue
        }
        .background(Theme.backdrop.opacity(0.38))
    }

    /// Clicking it opens the real window — the thumbnail is where you notice
    /// the lyrics are wrong, so it should be one click from where you fix it.
    private var stagePreview: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            openWindow(id: SpotifyKaraokeApp.lyricsWindowID)
        } label: {
            StagePreview(width: Self.stageWidth)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .help("Open the lyrics window")
    }

    @ViewBuilder
    private var queue: some View {
        if let next = library.upNext, next.tracks.count > 1 {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // The first entry is the track playing now, already shown
                    // above — the queue starts after it.
                    ForEach(Array(next.tracks.dropFirst().enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(Theme.timecode).foregroundStyle(Theme.upcoming)
                                .frame(width: 18, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.name).font(.system(size: 12)).lineLimit(1)
                                Text(track.artist).font(.system(size: 10.5))
                                    .foregroundStyle(Theme.upcoming).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(TrackRow.time(track.duration))
                                .font(Theme.timecode).foregroundStyle(Theme.upcoming)
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
                    .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
        }
    }

    /// Labelled explicitly: these symbols describe themselves as "Back" and
    /// "Forward", which to VoiceOver sounds like navigation, not tracks.
    private func transport(_ symbol: String, _ label: String, large: Bool = false,
                           tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 17 : 13, weight: .semibold))
                .foregroundStyle(tint == nil ? .white : Color.black.opacity(0.82))
                .frame(width: large ? 44 : 32, height: large ? 44 : 32)
                .background(Circle().fill(tint ?? Color.white.opacity(0.10)))
                .shadow(color: .black.opacity(tint == nil ? 0 : 0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
