import SwiftUI

/// Up Next: who's next, and the queue — reorderable when it's the requests
/// playlist, as on the Mac.
struct UpNextView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                if let next = store.state?.next {
                    Section("Next") {
                        row(next.name, next.artist, singer: next.singer)
                    }
                }
                Section {
                    let queue = Array((store.state?.queue ?? []).enumerated())
                    if queue.isEmpty {
                        Text("Nothing queued.").foregroundStyle(.secondary)
                    }
                    ForEach(queue, id: \.offset) { _, song in
                        row(song.name, song.artist, singer: song.singer)
                    }
                    .onMove(perform: editable ? { from, to in
                        guard let first = from.first else { return }
                        // List's destination counts the row being moved.
                        store.move(from: first, to: to > first ? to - 1 : to)
                    } : nil)
                } header: {
                    Text("Queue")
                } footer: {
                    if !editable, !(store.state?.queue ?? []).isEmpty {
                        Text("Only the requests playlist can be rearranged from here.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Up Next")
            .toolbar { if editable { EditButton() } }
            .refreshable { await store.refresh() }
        }
    }

    private var editable: Bool { store.state?.queueEditable == true }

    private func row(_ name: String, _ artist: String, singer: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let singer {
                Text(singer).font(.caption.weight(.heavy)).foregroundStyle(Theme.pink)
            }
            Text(name).font(.body.weight(.medium)).lineLimit(1)
            Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The player's library — Apple Music's on the Mac, or all of Spotify — to
/// play a song now or, on Apple Music, add it to the requests.
struct SearchView: View {
    @Environment(RemoteStore.self) private var store
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var chosen: SearchHit?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List(hits) { hit in
                Button { chosen = hit } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            Text(hit.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let level = hit.level { LevelChip(level: level) }
                    }
                }
            }
            .overlay {
                if hits.isEmpty {
                    ContentUnavailableView(searching ? "Searching…" : query.count < 2 ? "Search the Library" : "No Songs Found",
                                           systemImage: "magnifyingglass",
                                           description: Text(store.state?.source == "spotify" ? "All of Spotify, through the Mac's sign-in." : "The Mac's Apple Music library."))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Song or artist")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                searching = true
                hits = await store.search(query)
                searching = false
            }
            .confirmationDialog(chosen?.name ?? "", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                                titleVisibility: .visible) {
                if let hit = chosen {
                    Button("Play Now") { store.play(hit) }
                    if store.state?.canRequest == true, hit.databaseID != nil {
                        Button("Add to the Requests") {
                            Task {
                                let added = await store.request(hit)
                                toast = added ? "Added “\(hit.name)”" : "Couldn't add it"
                            }
                        }
                    }
                }
            } message: {
                Text(chosen?.artist ?? "")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 12)
                        .task { try? await Task.sleep(for: .seconds(2)); self.toast = nil }
                }
            }
        }
    }
}

/// How hard a song is to sing, as the Mac rated it.
struct LevelChip: View {
    let level: Int

    var body: some View {
        let (title, color): (String, Color) = switch level {
        case 1: ("Easy", .green)
        case 2: ("Medium", .yellow)
        default: ("Hard", Theme.pink)
        }
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color))
    }
}
