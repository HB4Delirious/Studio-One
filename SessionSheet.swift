import SwiftUI

/// The party request line: a QR code guests scan to add songs.
struct SessionSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var server = RequestServer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showing = Door.guests
    @AppStorage(RequestServer.guestLyricsKey) private var guestLyrics = true
    @AppStorage(RequestServer.guestHistoryKey) private var guestHistory = true

    /// Which code is on screen. Kept as one at a time and clearly labelled:
    /// two QR codes side by side is exactly how the remote gets handed to the
    /// room by mistake.
    private enum Door: String, CaseIterable, Identifiable {
        case guests = "For Guests"
        case remote = "My Remote"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Request line").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if server.running {
                        Picker("", selection: $showing) {
                            ForEach(Door.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()

                        if showing == .guests, let address = server.guestAddress {
                            live(address,
                                 blurb: "Guests scan this, give a name and pick from your library.",
                                 caution: "Guests give a nickname, then search what's on this Mac; their picks join the queue under their name, and they can't skip or pause. Everyone has to be on the same Wi-Fi. Anyone with this code can add a song — that's the point at a party, but don't share it further than the room.")
                        } else if let address = server.remoteAddress {
                            live(address,
                                 blurb: "Your own phone: transport, volume, key, search and the queue.",
                                 caution: "This one controls playback: play, pause, skip, scrub, fade, search and start anything in the library. Keep it to yourself — hand out the guest code instead.")
                        }
                    } else {
                        idle
                    }

                    if model.requestQueue != nil {
                        SettingsSection("Guest page") {
                            Toggle("Guests can follow the lyrics on their phones", isOn: $guestLyrics)
                                .font(.system(size: 12))
                                .info("A Lyrics tab on the guest page, in time with the screen, the line being sung lit in its duet colour, and who's up next during a break.")
                            Toggle("Returning guests see the songs they've sung before", isOn: $guestHistory)
                                .font(.system(size: 12))
                                .info("Found in History by the name they request under, so two guests using one name share a list. One tap requests one again.")
                        }
                    }

                    if !server.received.isEmpty {
                        Divider().overlay(Theme.hairline)
                        Text("REQUESTED").font(Theme.label).foregroundStyle(Theme.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(server.received.prefix(12).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 12)).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        // Short until there's a code to show.
        .frame(width: 430, height: server.running || !server.received.isEmpty ? 620
               : model.requestQueue == nil ? 220 : 340)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private func live(_ address: URL, blurb: String, caution: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                if let qr = RequestServer.qr(for: address, side: 260) {
                    Image(nsImage: qr)
                        .interpolation(.none)          // keep the modules crisp
                        .resizable().frame(width: 260, height: 260)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Text(blurb).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                InfoButton(caution)
            }

            HStack(spacing: 8) {
                Text(address.absoluteString)
                    .font(Theme.timecode).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address.absoluteString, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy the link, for anyone who can't scan")
            }

            HStack(spacing: 10) {
                Button("Play the Requests") { model.performOnRequestQueue { try await $0.playRequests() } }
                    .glassButton(prominent: true, tint: model.palette.accent)
                    .disabled(server.received.isEmpty)
                Button("Stop") { server.stop() }
                    .glassButton()
                Spacer()
            }
        }
    }

    /// Not started: what it is in a line, and the one button — or, following
    /// Spotify, the button that makes it possible.
    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.requestQueue == nil {
                Text("Guests request from your Apple Music library, so the request line needs Apple Music as the player.")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Switch to Apple Music") { model.changeSource(to: .appleMusic) }
                    .controlSize(.large)
                    .glassButton(prominent: true, tint: model.palette.accent)
            } else {
                HStack(spacing: 6) {
                    Text("Guests scan a code and add songs to “\(AppleMusicController.requestsPlaylist)”. A second code is your own remote.")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    InfoButton("Guests can only request what's already in your library — Apple Music's scripting searches your library, never the catalogue, and there's no way around that from outside the app.\n\nThe first time it starts, macOS may ask whether to allow incoming connections. That prompt needs your click.")
                }
                if let failure = server.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.sung)
                }
                Button("Start the Request Line") { server.start(model: model) }
                    .controlSize(.large)
                    .glassButton(prominent: true, tint: model.palette.accent)
            }
        }
    }
}
