import SwiftUI

/// The party request line: a QR code guests scan to add songs.
struct SessionSheet: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var server = RequestServer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showing = Door.guests

    /// Which code is on screen. Kept as one at a time and clearly labelled:
    /// two QR codes side by side is exactly how the remote gets handed to the
    /// room by mistake.
    private enum Door: String, CaseIterable, Identifiable {
        case guests = "For guests"
        case remote = "My remote"
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
                                 blurb: "Guests scan this, give a nickname, then search what's on this Mac. Their picks join the queue under their name. They can't skip or pause.",
                                 caution: "Everyone has to be on the same Wi-Fi. Anyone with this code can add a song — that's the point at a party, but it means don't share it further than the room.")
                        } else if let address = server.remoteAddress {
                            live(address,
                                 blurb: "Your own phone: play, pause, skip, scrub, search and start anything in the library.",
                                 caution: "This one controls playback. Keep it to yourself — hand out the guest code instead.")
                        }
                    } else {
                        idle
                    }

                    if !server.received.isEmpty {
                        Divider().overlay(Theme.hairline)
                        Text("REQUESTED").font(Theme.label).foregroundStyle(Theme.upcoming)
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
        .frame(width: 430, height: 600)
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

            Text(blurb).font(.system(size: 12)).foregroundStyle(Theme.upcoming)

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
                Button("Play the requests") { model.performOnBrowser { try await $0.playRequests() } }
                    .disabled(server.received.isEmpty)
                Button("Stop") { server.stop() }
                Spacer()
            }

            Text(caution).font(.system(size: 11)).foregroundStyle(Theme.upcoming)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two codes: one for guests to request songs, one to drive playback from your own phone. Requests land in a playlist called “\(AppleMusicController.requestsPlaylist)”.")
                .font(.system(size: 13))

            Text("They can only request what's already in your library — Apple Music's scripting interface searches your library, never the catalogue. There is no way around that from outside the app.")
                .font(.system(size: 11)).foregroundStyle(Theme.upcoming)

            if let failure = server.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.sung)
            }

            Button("Start the request line") { server.start(model: model) }
                .disabled(model.browser?.canTakeRequests != true)

            if model.browser?.canTakeRequests != true {
                Text("Switch the source to Apple Music first — the request line adds to a Music playlist, which Spotify's side can't do.")
                    .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
            }

            Text("The first time it starts, macOS may ask whether to allow incoming connections. That prompt needs your click; nothing can answer it for you.")
                .font(.system(size: 11)).foregroundStyle(Theme.upcoming)
        }
    }
}
