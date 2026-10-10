import SwiftUI

/// The playing song's title and artist, centred, with its cover above them
/// when there's room for one.
struct NowPlayingHeader: View {
    @EnvironmentObject private var model: KaraokeModel
    /// Nil leaves the cover out, for when the stage preview above already
    /// shows the song.
    var artworkSize: CGFloat?
    /// Tighter, with the key and tempo straight under it.
    var compact = false

    var body: some View {
        VStack(spacing: 16) {
            if let artworkSize { artwork(side: artworkSize) }
            VStack(spacing: 5) {
                Text(model.track?.name ?? "Nothing playing")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    // Reserved so the header keeps its height between one- and
                    // two-line titles — except compact, where the gap would sit
                    // between title and artist.
                    .lineLimit(2, reservesSpace: !compact)
                // A space rather than nothing, for the same reason.
                Text(model.track?.artist ?? " ")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, compact ? 14 : 20)
        .padding(.bottom, compact ? 8 : 20)
    }

    private func artwork(side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Group {
            if let url = model.track?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.backdrop
                }
            } else if let image = model.localArtwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Theme.backdrop
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.stroke(Theme.hairline))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
    }
}

/// Position bar you can drag to seek. Redraws off its own TimelineView because
/// the clock isn't @Published — polling only republishes twice a second, which
/// would make the playhead visibly step rather than glide.
struct Scrubber: View {
    @EnvironmentObject private var model: KaraokeModel
    @AppStorage(FrameRate.defaultsKey) private var targetFPS: Double = FrameRate.minimum
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: FrameRate.interval(for: targetFPS),
                                paused: !model.isPlaying)) { _ in
            let hasTrack = (model.track?.duration ?? 0) > 0
            let duration = max(1, model.track?.duration ?? 1)
            let live = hasTrack ? min(1, max(0, model.clock.position / duration)) : 0
            let fraction = scrub ?? live

            // Times flank the bar so it can run the full width of the window.
            HStack(spacing: 12) {
                // Nothing playing reads as blank, not as a one-second song.
                Text(hasTrack ? Self.timecode(fraction * duration) : "–:––")
                    .font(Theme.timecode)
                    .foregroundStyle(scrub == nil ? Theme.secondary : Theme.cue)
                    .frame(width: 42, alignment: .trailing)

                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.hairline)
                            .frame(height: 6)
                        Capsule()
                            .fill(model.palette.accent)
                            .frame(width: width * fraction, height: 6)
                        Circle()
                            .fill(.white)
                            .frame(width: scrub == nil ? 11 : 14, height: scrub == nil ? 11 : 14)
                            .offset(x: width * fraction - (scrub == nil ? 5.5 : 7))
                            .opacity(hasTrack ? 1 : 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .allowsHitTesting(hasTrack)
                    .gesture(
                        // minimumDistance 0 so a plain click seeks too.
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                scrub = min(1, max(0, value.location.x / width))
                            }
                            .onEnded { value in
                                let target = min(1, max(0, value.location.x / width))
                                // Seek only on release — every seek is an Apple
                                // Event, and firing one per drag sample floods it.
                                model.seek(to: target * duration)
                                scrub = nil
                            })
                }
                .frame(height: 16)

                Text(hasTrack ? Self.timecode(duration) : "–:––")
                    .font(Theme.timecode)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 42, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue(hasTrack ? "\(Self.timecode(fraction * duration)) of \(Self.timecode(duration))" : "Nothing playing")
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
