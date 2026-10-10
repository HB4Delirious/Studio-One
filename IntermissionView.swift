import SwiftUI

/// The lyrics screen during a break between songs (see `Intermission`): who's
/// up next, the code to request a song, the room's cheer for the song just
/// sung with the night's best, and when the next one starts. Laid out on the
/// lyrics screen's 16:9 design and scaled to the window, so the preview in the
/// Controls window shows it too.
struct IntermissionView: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var requests = RequestServer.shared
    @AppStorage(Applause.enabledKey) private var applauseOn = false
    @ObservedObject private var venue = VenueThemes.shared
    @ObservedObject private var games = PartyGames.shared
    @ObservedObject private var performances = Performances.shared
    let pause: Intermission

    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width / 1024, geo.size.height / 576)
            // Without the request code beside it, centred, as the standby
            // screen is: no empty half of the screen.
            let centred = requests.guestAddress == nil
            ZStack {
                Theme.backdrop.opacity(0.84)
                HStack(alignment: .center, spacing: 48 * unit) {
                    VStack(alignment: centred ? .center : .leading, spacing: 22 * unit) {
                        if let battle = games.battle { BattleBanner(battle: battle, unit: unit) }
                        upNext(unit, centred: centred)
                        if applauseOn {
                            CheerMeter(unit: unit, centred: centred)
                                .frame(maxWidth: centred ? 620 * unit : .infinity)
                        }
                        Countdown(endsAt: pause.endsAt, unit: unit)
                        // The venue's line for the room.
                        if !venue.current.message.isEmpty {
                            Text(venue.current.message)
                                .font(.system(size: 18 * unit, weight: .semibold, design: Theme.stageDesign))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(2)
                        }
                    }
                    .multilineTextAlignment(centred ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
                    if let address = requests.guestAddress {
                        // The song just sung, for its singer to keep, above
                        // the code to request; both smaller to fit.
                        if let recording = performances.latest(for: pause.endedURI,
                                                               since: pause.started.addingTimeInterval(-3600)) {
                            VStack(spacing: 22 * unit) {
                                RequestCode(address: Performances.link(recording, from: address), unit: unit,
                                            side: 140,
                                            caption: recording.singer.map { "\($0), your recording" } ?? "This song's recording")
                                RequestCode(address: address, unit: unit, side: 140)
                            }
                        } else {
                            RequestCode(address: address, unit: unit)
                        }
                    }
                }
                .padding(56 * unit)
            }
            // The venue's logo, small, in a corner.
            .overlay(alignment: .topTrailing) {
                if let logo = venue.logo, requests.guestAddress == nil {
                    Image(nsImage: logo)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 140 * unit, maxHeight: 60 * unit)
                        .opacity(0.85)
                        .padding(28 * unit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .transition(.opacity)
    }

    private func upNext(_ unit: CGFloat, centred: Bool) -> some View {
        let next = model.nextUp
        let singer = next.flatMap { requests.requester(name: $0.name, artist: $0.artist) }
        return VStack(alignment: centred ? .center : .leading, spacing: 8 * unit) {
            Text("UP NEXT")
                .font(.system(size: 18 * unit, weight: .heavy, design: Theme.stageDesign))
                .foregroundStyle(Theme.cue)
            Text(singer ?? next?.name ?? "Request a song!")
                .font(.system(size: 64 * unit, weight: .heavy, design: Theme.stageDesign))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            if let next {
                Text(singer == nil ? next.artist : "\(next.name) — \(next.artist)")
                    .font(.system(size: 26 * unit, weight: .semibold, design: Theme.stageDesign))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }
}

/// The cheer for the song just sung: a meter while the room is heard, then
/// the score and tonight's loudest.
private struct CheerMeter: View {
    @ObservedObject private var applause = Applause.shared
    let unit: CGFloat
    var centred = false

    var body: some View {
        switch applause.phase {
        case .listening(let who, _):
            VStack(alignment: centred ? .center : .leading, spacing: 12 * unit) {
                Text("Make some noise for \(who)!")
                    .font(.system(size: 28 * unit, weight: .bold, design: Theme.stageDesign))
                    .foregroundStyle(Theme.sung)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.cue, Theme.sung, Theme.part(.both)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(18 * unit, geo.size.width * applause.level))
                            .animation(.easeOut(duration: 0.12), value: applause.level)
                    }
                }
                .frame(height: 18 * unit)
            }
        case .scored(let score, let who):
            VStack(alignment: centred ? .center : .leading, spacing: 10 * unit) {
                HStack(alignment: .firstTextBaseline, spacing: 14 * unit) {
                    Text("\(score)")
                        .font(.system(size: 64 * unit, weight: .heavy, design: Theme.stageDesign))
                        .foregroundStyle(Theme.sung)
                        .monospacedDigit()
                    Text("for \(who)")
                        .font(.system(size: 24 * unit, weight: .semibold, design: Theme.stageDesign))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                let best = Applause.leaderboard()
                if !best.isEmpty {
                    Text("Tonight's loudest: " + best.enumerated().map { index, entry in
                        "\(index + 1). \(entry.singer ?? entry.name) \(entry.applause ?? 0)"
                    }.joined(separator: "   "))
                        .font(.system(size: 17 * unit, weight: .semibold, design: Theme.stageDesign))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .transition(.scale.combined(with: .opacity))
        case .idle:
            EmptyView()
        }
    }
}

/// When the next song starts.
private struct Countdown: View {
    let endsAt: Date?
    let unit: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(at: context.date))
                .font(.system(size: 18 * unit, weight: .semibold, design: Theme.stageDesign))
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
        }
    }

    private func text(at now: Date) -> String {
        guard let endsAt else { return "The next song starts when the host presses Play" }
        let left = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        return "Next song in \(left / 60):\(String(format: "%02d", left % 60))"
    }
}

/// The request line's guest code, to scan from the room. Drawn once.
struct RequestCode: View {
    let address: URL
    let unit: CGFloat
    var side: CGFloat = 210
    var caption = "Scan to request a song"
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 12 * unit) {
            Group {
                if let image {
                    Image(nsImage: image).interpolation(.none).resizable()
                } else {
                    Color.white
                }
            }
            .frame(width: side * unit, height: side * unit)
            .padding(14 * unit * side / 210)
            .background(RoundedRectangle(cornerRadius: 22 * unit * side / 210, style: .continuous).fill(.white))
            Text(caption)
                .font(.system(size: 18 * unit, weight: .bold, design: Theme.stageDesign))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: (side + 60) * unit)
        }
        .task(id: address) { image = RequestServer.qr(for: address, side: 420) }
    }
}
