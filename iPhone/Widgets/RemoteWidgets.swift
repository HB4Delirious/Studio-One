import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RemoteWidgets: WidgetBundle {
    var body: some Widget {
        RemoteLiveActivity()
    }
}

private let pink = Color(red: 0.91, green: 0.22, blue: 0.56)
private let ink = Color(red: 0.06, green: 0.05, blue: 0.11)

/// The song playing on the Lock Screen and in the Dynamic Island: who's
/// singing, the progress (running by itself between updates), who's next,
/// and play/pause and skip.
struct RemoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .padding(16)
                .activityBackgroundTint(ink.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.mic").font(.title2).foregroundStyle(pink).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Buttons(playing: state.playing).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(state.title).font(.headline).lineLimit(1)
                        Text(state.singer.map { "\($0) is singing" } ?? state.artist)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        Progress(state: state)
                        if let next = NextLine(state: state).text {
                            Text(next).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: "music.mic").foregroundStyle(pink)
            } compactTrailing: {
                if state.playing, state.ends > Date() {
                    ProgressView(timerInterval: state.started...state.ends, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.circular)
                    .tint(pink)
                    .frame(width: 18, height: 18)
                } else {
                    Image(systemName: state.playing ? "music.note" : "pause.fill").foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: "music.mic").foregroundStyle(pink)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: RemoteActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(pink)
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Buttons(playing: state.playing)
            }
            Progress(state: state)
            if stale {
                Text("Open S1 Remote for the latest").font(.caption2).foregroundStyle(.secondary)
            } else if !breakShowsNext, let next = NextLine(state: state).text {
                Text(next).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }

    /// In a break, who's next is the news; the song just sung isn't.
    private var breakShowsNext: Bool { state.intermission && state.nextTitle != nil }

    private var title: String {
        breakShowsNext ? (state.nextSinger ?? state.nextTitle ?? "") : state.title
    }

    private var subtitle: String {
        guard breakShowsNext else { return state.artist }
        return state.nextSinger != nil ? "Up next: \(state.nextTitle ?? "")" : "Up next"
    }

    private var heading: String {
        if state.intermission { return breakShowsNext ? "BREAK · UP NEXT" : "BREAK" }
        if state.houseMusic { return "HOUSE MUSIC" }
        return state.singer.map { "\($0.uppercased()) IS SINGING" } ?? "NOW PLAYING"
    }
}

private struct Buttons: View {
    let playing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(pink))
            }
            .buttonStyle(.plain)
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }
}

/// While playing, a bar that runs by itself from the song's start to its
/// end; paused or in a break, where it stopped, or the break's countdown.
private struct Progress: View {
    let state: RemoteActivityAttributes.ContentState

    var body: some View {
        if state.intermission, let ends = state.breakEnds, ends > Date() {
            HStack(spacing: 4) {
                Text("Next song in")
                Text(timerInterval: Date()...ends, countsDown: true).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
        } else if state.playing, state.ends > state.started {
            ProgressView(timerInterval: state.started...state.ends, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(pink)
        } else {
            let total = state.ends.timeIntervalSince(state.started)
            ProgressView(value: min(total, state.pausedAt ?? 0), total: max(1, total))
                .tint(.white.opacity(0.5))
        }
    }
}

private struct NextLine {
    let state: RemoteActivityAttributes.ContentState

    var text: String? {
        guard let title = state.nextTitle else { return nil }
        return "Up next: " + (state.nextSinger.map { "\($0) · \(title)" } ?? title)
    }
}
