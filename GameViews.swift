import SwiftUI

/// Name that tune, on the room's screen: the song plays, its title and lyrics
/// hidden, until someone guesses it on their phone — then who, how fast, and
/// the answer. Laid out on the 16:9 design like the break screen.
struct NameThatTuneView: View {
    @ObservedObject private var requests = RequestServer.shared
    let tune: PartyGames.Tune

    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width / 1024, geo.size.height / 576)
            ZStack {
                Theme.backdrop.opacity(0.92)
                HStack(spacing: 56 * unit) {
                    VStack(alignment: .leading, spacing: 14 * unit) {
                        Text("NAME THAT TUNE")
                            .font(.system(size: 22 * unit, weight: .heavy, design: Theme.stageDesign))
                            .tracking(2 * unit)
                            .foregroundStyle(Theme.cue)
                        if tune.revealed {
                            Text(tune.winner.map { "\($0) got it\(tune.seconds.map { " in \($0) s" } ?? "")!" }
                                 ?? "Nobody got it!")
                                .font(.system(size: 54 * unit, weight: .heavy, design: Theme.stageDesign))
                                .foregroundStyle(Theme.sung)
                                .lineLimit(2).minimumScaleFactor(0.6)
                            Text("\(tune.answer) — \(tune.artist)")
                                .font(.system(size: 30 * unit, weight: .bold, design: Theme.stageDesign))
                                .foregroundStyle(.white)
                                .lineLimit(2).minimumScaleFactor(0.6)
                        } else {
                            Text("What's this song?")
                                .font(.system(size: 60 * unit, weight: .heavy, design: Theme.stageDesign))
                                .foregroundStyle(.white)
                            Text(requests.guestAddress == nil ? "Shout it out!" : "Guess on your phone — first right answer wins.")
                                .font(.system(size: 24 * unit, weight: .semibold, design: Theme.stageDesign))
                                .foregroundStyle(.white.opacity(0.75))
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let seconds = Int(context.date.timeIntervalSince(tune.started))
                                Text("\(seconds) s · \(tune.guesses) guess\(tune.guesses == 1 ? "" : "es")")
                                    .font(.system(size: 20 * unit, weight: .semibold, design: Theme.stageDesign))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .monospacedDigit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !tune.revealed, let address = requests.guestAddress {
                        RequestCode(address: address, unit: unit)
                    }
                }
                .padding(56 * unit)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .transition(.opacity)
    }
}

/// A song battle on the break screen: the first score to beat, then the winner.
struct BattleBanner: View {
    let battle: PartyGames.Battle
    let unit: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * unit) {
            Text("SONG BATTLE")
                .font(.system(size: 16 * unit, weight: .heavy, design: Theme.stageDesign))
                .tracking(1.5 * unit)
                .foregroundStyle(Theme.part(.both))
            if battle.isDecided {
                HStack(alignment: .firstTextBaseline, spacing: 14 * unit) {
                    score(battle.first)
                    Text("vs").font(.system(size: 18 * unit, weight: .bold, design: Theme.stageDesign))
                        .foregroundStyle(.white.opacity(0.5))
                    score(battle.second)
                }
                Text(battle.winner.map { "\($0.who) wins!" } ?? "It's a tie!")
                    .font(.system(size: 40 * unit, weight: .heavy, design: Theme.stageDesign))
                    .foregroundStyle(Theme.sung)
            } else if let first = battle.first.score {
                Text("\(battle.first.who) scored \(first) — \(battle.second.who), beat that!")
                    .font(.system(size: 24 * unit, weight: .bold, design: Theme.stageDesign))
                    .foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.6)
            } else {
                Text("\(battle.first.who) vs \(battle.second.who) — cheer loudest for your favourite!")
                    .font(.system(size: 22 * unit, weight: .bold, design: Theme.stageDesign))
                    .foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.6)
            }
        }
    }

    private func score(_ contender: PartyGames.Contender) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * unit) {
            Text(contender.who)
                .font(.system(size: 22 * unit, weight: .semibold, design: Theme.stageDesign))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Text("\(contender.score ?? 0)")
                .font(.system(size: 32 * unit, weight: .heavy, design: Theme.stageDesign))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }
}

/// The Controls window's Games popover: each game, with what it needs.
struct GamesPopover: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var games = PartyGames.shared
    @ObservedObject private var requests = RequestServer.shared
    @AppStorage(BreakMode.defaultsKey) private var breakMode: BreakMode = .off
    @AppStorage(Applause.enabledKey) private var applauseOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Party Games").font(.system(size: 15, weight: .bold))

            game("Song Battle", symbol: "flag.2.crossed.fill",
                 detail: battleDetail) {
                if games.battle != nil {
                    Button("End") { games.endBattle() }
                } else {
                    Button("Start") {
                        if let track = model.track, let next = model.nextUp { games.startBattle(current: track, next: next) }
                    }
                    .disabled(model.track == nil || model.nextUp == nil || breakMode == .off || !applauseOn)
                }
            }

            game("Finish the Lyric", symbol: "text.badge.minus",
                 detail: games.finishURI != nil && games.finishURI == model.track?.uri
                    ? "On for this song: \(games.finishMasks.count) lines lose their endings later on."
                    : "Later in this song, the end of a few lines goes blank — on the screen and on phones.") {
                if games.finishURI != nil && games.finishURI == model.track?.uri {
                    Button("Stop") { games.endFinishTheLyric() }
                } else {
                    Button("Start") {
                        if let track = model.track { games.startFinishTheLyric(uri: track.uri, lines: model.lines) }
                    }
                    .disabled(model.track == nil || model.lyricsState != .synced)
                }
            }

            game("Name That Tune", symbol: "questionmark.bubble.fill",
                 detail: tuneDetail) {
                if let tune = games.tune, tune.uri == model.track?.uri {
                    if !tune.revealed { Button("Reveal") { games.reveal() } }
                    Button("End") { games.endNameThatTune() }
                } else {
                    Button("Start") { if let track = model.track { games.startNameThatTune(track) } }
                        .disabled(model.track == nil)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var battleDetail: String {
        if breakMode == .off || !applauseOn {
            return "Needs the break and the applause meter — Settings › Between Songs."
        }
        if let battle = games.battle {
            return battle.isDecided
                ? (battle.winner.map { "\($0.who) won." } ?? "A tie.")
                : "\(battle.first.who) against \(battle.second.who): each break's cheer scores them."
        }
        return model.nextUp.map { "This song against “\($0.name)”: the louder cheer wins." }
            ?? "This song against the next one — nothing's queued yet."
    }

    private var tuneDetail: String {
        if let tune = games.tune, tune.uri == model.track?.uri {
            return tune.revealed ? "Revealed." : "Running: \(tune.guesses) guesses so far."
        }
        return requests.guestAddress == nil
            ? "This song's title and lyrics hidden; the room shouts it out. With the request line on, guests guess on their phones."
            : "This song's title and lyrics hidden; guests guess on their phones, first right answer wins."
    }

    private func game<Actions: View>(_ title: String, symbol: String, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(model.palette.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) { actions() }.controlSize(.small)
        }
    }
}
