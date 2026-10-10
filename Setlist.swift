import AppKit
import SwiftUI

/// What was sung, night by night.
///
/// A song counts once it has played for thirty seconds, so skips don't fill
/// the list. A night runs from 6 am to 6 am: a party that goes past midnight
/// is one night, not two. Kept as one small JSON file per night.
struct SetlistEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    let at: Date
    let name: String
    let artist: String
    let uri: String
    let source: String
    let singer: String?
    let key: String?
    let tempo: Double?
    /// The room's cheer after it, out of 100 (see `Applause`).
    var applause: Int? = nil
}

@MainActor
final class Setlists: ObservableObject {

    static let shared = Setlists()

    /// Bumped on every change, so an open history window refreshes.
    @Published private(set) var revision = 0

    private let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Studio One/Setlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The night a moment belongs to: six hours earlier's calendar day.
    static func night(for date: Date) -> String {
        dayFormat.string(from: date.addingTimeInterval(-6 * 3600))
    }

    static func title(for night: String) -> String {
        guard let date = dayFormat.date(from: night) else { return night }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    /// "Sat, Oct 4, 2026", for History's sidebar.
    static func shortTitle(for night: String) -> String {
        guard let date = dayFormat.date(from: night) else { return night }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    private func file(_ night: String) -> URL { folder.appendingPathComponent("\(night).json") }

    func record(_ entry: SetlistEntry) {
        let night = Self.night(for: entry.at)
        var list = entries(night)
        list.append(entry)
        save(list, night)
    }

    /// The applause for the song's latest entry tonight.
    func setApplause(_ score: Int, for uri: String) {
        let night = Self.night(for: Date())
        var list = entries(night)
        guard let index = list.lastIndex(where: { $0.uri == uri }) else { return }
        list[index].applause = score
        save(list, night)
    }

    private func save(_ list: [SetlistEntry], _ night: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(list) {
            try? data.write(to: file(night), options: .atomic)
        }
        revision += 1
    }

    func nights() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted(by: >)
    }

    func entries(_ night: String) -> [SetlistEntry] {
        guard let data = try? Data(contentsOf: file(night)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SetlistEntry].self, from: data)) ?? []
    }

    func delete(_ night: String) {
        try? FileManager.default.removeItem(at: file(night))
        revision += 1
    }

    /// A song a guest has sung here, gathered across nights.
    struct PastSong {
        let persistentID: String
        let name: String
        let artist: String
        var times: Int
        var best: Int?
        var last: Date
    }

    /// What someone has sung, by the name they requested under — Apple Music
    /// songs only, which are what the request line can queue. Most recent
    /// first.
    func pastSongs(of singer: String, limit: Int = 10) -> [PastSong] {
        Self.pastSongs(in: nights().flatMap { entries($0) }, of: singer, limit: limit)
    }

    static func pastSongs(in entries: [SetlistEntry], of singer: String, limit: Int = 10) -> [PastSong] {
        let wanted = folded(singer)
        guard !wanted.isEmpty else { return [] }
        var songs: [String: PastSong] = [:]
        for entry in entries where entry.uri.hasPrefix("am:") && entry.singer.map(folded) == wanted {
            let id = String(entry.uri.dropFirst(3))
            guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else { continue }
            var song = songs[id] ?? PastSong(persistentID: id, name: entry.name, artist: entry.artist,
                                             times: 0, best: nil, last: entry.at)
            song.times += 1
            if let score = entry.applause { song.best = max(song.best ?? 0, score) }
            song.last = max(song.last, entry.at)
            songs[id] = song
        }
        return songs.values.sorted { $0.last > $1.last }.prefix(limit).map { $0 }
    }

    /// Names as guests type them: "sam ", "Sam" and "SAM" are one person.
    static func folded(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func text(for entries: [SetlistEntry]) -> String {
        entries.map { entry in
            let time = entry.at.formatted(date: .omitted, time: .shortened)
            let who = entry.singer.map { " — sung by \($0)" } ?? ""
            let key = entry.key.map { " [\($0)]" } ?? ""
            return "\(time)  \(entry.name) — \(entry.artist)\(key)\(who)"
        }.joined(separator: "\n")
    }
}

// MARK: - Queue a night again

extension AppleMusicController {

    /// Library database IDs — what a request is made with — for persistent
    /// IDs. Songs no longer in the library are left out. One short Apple
    /// Event each rather than one long script, so the poll and the transport,
    /// queued for the same player, get in between.
    func databaseIDs(persistentIDs: [String]) async -> [String: Int] {
        var found: [String: Int] = [:]
        for id in persistentIDs where !id.isEmpty && id.allSatisfy(\.isHexDigit) {
            let raw = try? await scripts.text("""
            tell application id "com.apple.Music"
                try
                    return (database ID of (first track of library playlist 1 whose persistent ID is "\(id)")) as text
                on error
                    return ""
                end try
            end tell
            """)
            if let value = raw.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                found[id] = value
            }
        }
        return found
    }

    /// Adds songs to the requests playlist, by persistent ID, in order.
    /// Returns how many were found; songs since removed from the library are
    /// skipped rather than failing the rest.
    func queueAgain(persistentIDs: [String]) async throws -> Int {
        let ids = persistentIDs.filter { !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }
        guard !ids.isEmpty else { return 0 }
        let list = ids.map { "\"\($0)\"" }.joined(separator: ", ")
        let raw = try await scripts.text("""
        tell application id "com.apple.Music"
            set pname to "\(Self.requestsPlaylist)"
            try
                set p to (first user playlist whose name is pname)
            on error
                set p to make new user playlist with properties {name:pname}
            end try
            set added to 0
            repeat with pid in {\(list)}
                try
                    set tr to (first track of library playlist 1 whose persistent ID is (contents of pid))
                    duplicate tr to p
                    set added to added + 1
                end try
            end repeat
            return added as text
        end tell
        """)
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

// MARK: - Window

/// History: the nights down a glass sidebar, as Settings has its panes, and
/// the night picked — its count of songs and singers, its loudest cheer, and
/// what can be done with it — over the songs sung.
struct SetlistSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var store = Setlists.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var message: String?
    /// The night awaiting confirmation: deleting can't be undone.
    @State private var pendingDelete: String?

    var body: some View {
        let nights = store.nights()
        let _ = store.revision
        HStack(spacing: 0) {
            sidebar(nights)
                .frame(width: 210)
                .frame(maxHeight: .infinity)
                .glassPane(cornerRadius: Chrome.paneRadius - 4)
                .padding(Chrome.gutter)

            VStack(spacing: 0) {
                if let night = selected ?? nights.first {
                    detail(night)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 26)).foregroundStyle(Theme.secondary)
                        Text("Nothing sung yet").font(.system(size: 15, weight: .semibold))
                        Text("Every song that plays for thirty seconds is added here, night by night, with who sang it.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack {
                    if let message {
                        Text(message).font(Theme.label).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .glassButton(prominent: true, tint: model.palette.accent)
                }
                .controlSize(.large)
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .frame(width: 860, height: 560)
        .background(Theme.panel)
        .confirmationDialog("Delete this night's history?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let night = pendingDelete {
                    store.delete(night)
                    selected = nil
                    message = nil
                }
                pendingDelete = nil
            }
        } message: {
            Text("\(pendingDelete.map(Setlists.title(for:)) ?? "") — every song sung that night. This can't be undone.")
        }
    }

    private func sidebar(_ nights: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("History")
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(nights, id: \.self) { night in
                        let isSelected = night == (selected ?? nights.first)
                        Button {
                            selected = night
                            message = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Setlists.shortTitle(for: night))
                                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                let count = store.entries(night).count
                                Text("\(count) song\(count == 1 ? "" : "s")")
                                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: Chrome.rowRadius + 2, style: .continuous)
                                .fill(isSelected ? model.palette.accent.opacity(0.34) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    private func detail(_ night: String) -> some View {
        let entries = store.entries(night)
        let fromMusic = entries.filter { $0.source == MusicSource.appleMusic.rawValue }
        let singers = Set(entries.compactMap { $0.singer.map(Setlists.folded) }).count
        let loudest = entries.filter { $0.applause != nil }.max { ($0.applause ?? 0) < ($1.applause ?? 0) }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Setlists.title(for: night)).font(.system(size: 22, weight: .bold))
                HStack(spacing: 14) {
                    stat("music.note", "\(entries.count) song\(entries.count == 1 ? "" : "s")")
                    if singers > 0 { stat("person.2.fill", "\(singers) singer\(singers == 1 ? "" : "s")") }
                    if let loudest, let score = loudest.applause {
                        stat("hands.clap.fill", "Loudest: \(score), \(loudest.singer ?? loudest.name)")
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Setlists.title(for: night) + "\n"
                                                       + Setlists.text(for: entries), forType: .string)
                        message = "Copied."
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { queueAgain(fromMusic) } label: { Label("Queue Again", systemImage: "text.badge.plus") }
                        .disabled(fromMusic.isEmpty || model.musicSource != .appleMusic)
                        .help("Adds the night's Apple Music songs to the requests playlist, in order")
                    Button(role: .destructive) { pendingDelete = night } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                }
                .controlSize(.small)
                .glassButton()
                .padding(.top, 4)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(spacing: 12) {
                            Text(entry.at.formatted(date: .omitted, time: .shortened))
                                .font(Theme.timecode)
                                .foregroundStyle(Theme.secondary).frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(entry.artist).font(.system(size: 11))
                                    .foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let key = entry.key {
                                Text(key)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.white.opacity(0.08)))
                                    .help("Key")
                            }
                            if let applause = entry.applause {
                                Label("\(applause)", systemImage: "hands.clap.fill")
                                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Theme.sung)
                                    .help("The room's applause, out of 100")
                            }
                            Text(entry.singer ?? "")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.cue)
                                .frame(width: 110, alignment: .trailing).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Chrome.rowRadius, style: .continuous)
                            .fill(Color.white.opacity(0.03)))
                        .padding(.horizontal, 10).padding(.vertical, 2)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
    }

    private func queueAgain(_ entries: [SetlistEntry]) {
        guard let music = model.browser as? AppleMusicController else { return }
        let ids = entries.map { $0.uri.hasPrefix("am:") ? String($0.uri.dropFirst(3)) : "" }
        message = "Adding…"
        Task {
            do {
                let added = try await music.queueAgain(persistentIDs: ids)
                message = "Added \(added) of \(entries.count) to “\(AppleMusicController.requestsPlaylist)”."
                model.refreshNextUp()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
