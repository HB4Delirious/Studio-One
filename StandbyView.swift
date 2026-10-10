import AppKit
import SwiftUI

/// The room's screen with no song: Studio One's mark, what's up next when the
/// player knows, and the code to request when the request line is on — never
/// a message meant for the host ("isn't open", "can't reach"), which the
/// Controls window explains instead. Laid out on the lyrics screen's 16:9
/// design and scaled to the window, like the break screen.
struct StandbyView: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var requests = RequestServer.shared
    @ObservedObject private var venue = VenueThemes.shared

    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width / 1024, geo.size.height / 576)
            HStack(spacing: 64 * unit) {
                VStack(alignment: requests.guestAddress == nil ? .center : .leading, spacing: 14 * unit) {
                    // The venue's logo and name, else Studio One's.
                    if let logo = venue.logo {
                        Image(nsImage: logo)
                            .resizable().scaledToFit()
                            .frame(maxWidth: 360 * unit, maxHeight: 150 * unit)
                    } else if let icon = Self.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 132 * unit, height: 132 * unit)
                            .shadow(color: .black.opacity(0.4), radius: 18 * unit, y: 8 * unit)
                    }
                    Text(venue.current.venueName.isEmpty ? "Studio One" : venue.current.venueName)
                        .font(.system(size: 60 * unit, weight: .heavy, design: Theme.stageDesign))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    if !venue.current.message.isEmpty {
                        Text(venue.current.message)
                            .font(.system(size: 26 * unit, weight: .bold, design: Theme.stageDesign))
                            .foregroundStyle(Theme.sung)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                    }
                    if model.connection == .ready, let next = model.nextUp {
                        Text("Up next: \(next.name) — \(next.artist)")
                            .font(.system(size: 22 * unit, weight: .semibold, design: Theme.stageDesign))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    } else if requests.guestAddress != nil {
                        Text("Scan the code to request a song")
                            .font(.system(size: 22 * unit, weight: .semibold, design: Theme.stageDesign))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if let address = requests.guestAddress {
                    RequestCode(address: address, unit: unit)
                }
            }
            .padding(56 * unit)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The app's own artwork, from the bundle — the light version, as the
    /// guest page uses, rather than the Dock's, which follows the system.
    static let icon: NSImage? = Bundle.main.url(forResource: "StudioOne", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))
}

/// The room's screen while a song plays without lyrics to follow — loading,
/// none found, or none to sing: its title and artist, large, rather than a
/// note for the host.
struct SongCard: View {
    let track: PlayerTrack?
    var note: String?

    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width / 1024, geo.size.height / 576)
            VStack(spacing: 12 * unit) {
                Text(track?.name ?? "")
                    .font(.system(size: 56 * unit, weight: .heavy, design: Theme.stageDesign))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(track?.artist ?? "")
                    .font(.system(size: 26 * unit, weight: .semibold, design: Theme.stageDesign))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                if let note {
                    Text(note.uppercased())
                        .font(.system(size: 15 * unit, weight: .heavy, design: Theme.stageDesign))
                        .tracking(1.5 * unit)
                        .foregroundStyle(Theme.cue)
                        .padding(.top, 10 * unit)
                }
            }
            .padding(56 * unit)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
