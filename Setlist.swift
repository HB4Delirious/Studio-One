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

    private func file(_ night: String) -> URL { folder.appendingPathComponent("\(night).json") }

    func record(_ entry: SetlistEntry) {
        let night = Self.night(for: entry.at)
        var list = entries(night)
        list.append(entry)
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

    /// Adds songs to the requests playlist, by persistent ID, in order.
    /// Returns how many were found; songs since removed from the library are
    /// skipped rather than failing the rest.
    func queueAgain(persistentIDs: [String]) async throws -> Int {
        let ids = persistentIDs.filter { !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }
        guard !ids.isEmpty else { return 0 }
        let list = ids.map { "\"\($0)\"" }.joined(separator: ", ")
        let raw = try await runScript("""
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

struct SetlistSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var store = Setlists.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var message: String?

    var body: some View {
        let nights = store.nights()
        let _ = store.revision
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().overlay(Theme.hairline)

            if nights.isEmpty {
                Text("Nothing yet. Every song that plays for thirty seconds is added here, night by night, with who sang it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.upcoming)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
            } else {
                HStack(spacing: 0) {
                    List(nights, id: \.self, selection: $selected) { night in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Setlists.title(for: night)).font(.system(size: 12, weight: .medium))
                            Text("\(store.entries(night).count) songs")
                                .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                        }
                    }
                    .frame(width: 230)
                    Divider().overlay(Theme.hairline)
                    detail(selected ?? nights.first!)
                }
            }
        }
        .frame(width: 760, height: 480)
        .background(Theme.panel)
    }

    private func detail(_ night: String) -> some View {
        let entries = store.entries(night)
        let fromMusic = entries.filter { $0.source == MusicSource.appleMusic.rawValue }
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.at.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(Theme.upcoming).frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(entry.artist).font(.system(size: 11))
                                    .foregroundStyle(Theme.upcoming).lineLimit(1)
                            }
                            Spacer()
                            if let key = entry.key {
                                Text(key).font(.system(size: 11)).foregroundStyle(Theme.upcoming)
                            }
                            Text(entry.singer ?? "")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.cue)
                                .frame(width: 110, alignment: .trailing).lineLimit(1)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            HStack {
                if let message {
                    Text(message).font(Theme.label).foregroundStyle(Theme.upcoming)
                }
                Spacer()
                Button("Delete night") { store.delete(night); selected = nil; message = nil }
                Button("Copy list") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Setlists.title(for: night) + "\n"
                                                   + Setlists.text(for: entries), forType: .string)
                    message = "Copied."
                }
                Button("Queue it again") { queueAgain(fromMusic) }
                    .disabled(fromMusic.isEmpty || model.musicSource != .appleMusic)
                    .help("Adds the night's Apple Music songs to the requests playlist, in order")
            }
            .controlSize(.small)
            .padding(12)
        }
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
