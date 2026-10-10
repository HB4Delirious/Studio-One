import SwiftUI

/// The song playing, who's singing, and everything the host reaches for:
/// play, skip, fade, seek, volume, key and tempo.
struct NowPlayingView: View {
    @Environment(RemoteStore.self) private var store
    @State private var showSettings = false
    @State private var scrubbing: Double?
    @State private var volume: Double?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if !store.reachable { unreachable }
                    cover
                    titles
                    if let state = store.state, state.name != nil {
                        progress(state)
                        transport(state)
                        volumeRow(state)
                        keyAndTempo(state)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
            }
            .background(backdrop)
            .navigationTitle(store.pairing?.name ?? "Studio One")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { await store.refresh() }
        }
    }

    private var backdrop: some View {
        ZStack {
            Theme.ink
            if let art = store.artwork {
                Image(uiImage: art).resizable().scaledToFill().blur(radius: 60).opacity(0.45)
            }
            LinearGradient(colors: [.clear, Theme.ink], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var unreachable: some View {
        Label(store.finding ? "Looking for Studio One on the Wi-Fi…" : "Can't reach Studio One — is the Mac awake, and this phone on its Wi-Fi?",
              systemImage: "wifi.exclamationmark")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var cover: some View {
        Group {
            if let art = store.artwork {
                Image(uiImage: art).resizable().scaledToFit()
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 70, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        .frame(maxWidth: 270)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var titles: some View {
        let state = store.state
        VStack(spacing: 6) {
            if state?.intermission == true {
                breakBadge(ends: state?.breakEnds.map(Date.init(timeIntervalSince1970:)))
            } else if state?.house == true {
                badge("HOUSE MUSIC", detail: nil)
            } else if let singer = state?.singer {
                badge("NOW SINGING", detail: singer)
            }
            Text(state?.name ?? "Nothing playing")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            if let artist = state?.artist {
                Text(artist).font(.body).foregroundStyle(.secondary)
            }
        }
    }

    private func breakBadge(ends: Date?) -> some View {
        HStack(spacing: 6) {
            Text("BREAK").font(.caption.weight(.heavy)).foregroundStyle(Theme.pink)
            if let ends, ends > Date() {
                Text("next song in \(Text(timerInterval: Date()...ends, countsDown: true))")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private func badge(_ label: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.weight(.heavy)).foregroundStyle(Theme.pink)
            if let detail { Text(detail).font(.caption.weight(.semibold)) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private func progress(_ state: RemoteState) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(1, state.duration ?? 1)
            let shown = scrubbing ?? store.position
            VStack(spacing: 2) {
                Slider(value: Binding(get: { shown }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                    if !editing, let to = scrubbing {
                        store.seek(to: to)
                        scrubbing = nil
                    }
                }
                HStack {
                    Text(time(shown))
                    Spacer()
                    Text("−" + time(duration - shown))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func transport(_ state: RemoteState) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 44) {
                Button { store.command("prev") } label: { Image(systemName: "backward.fill") }
                    .font(.title)
                Button { store.command("playpause") } label: {
                    Image(systemName: state.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .frame(width: 76, height: 76)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                Button { store.command("next") } label: { Image(systemName: "forward.fill") }
                    .font(.title)
            }
            .foregroundStyle(.white)
            Button { store.command("fade") } label: {
                Label("Fade Out", systemImage: "speaker.wave.1.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
        }
    }

    private func volumeRow(_ state: RemoteState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: Binding(get: { volume ?? Double(state.volume ?? 100) },
                                  set: { volume = $0 }), in: 0...100) { editing in
                if !editing, let value = volume {
                    store.setVolume(Int(value))
                    // Held until the Mac's own reading catches up.
                    Task { try? await Task.sleep(for: .seconds(3)); volume = nil }
                }
            }
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    private func keyAndTempo(_ state: RemoteState) -> some View {
        VStack(spacing: 10) {
            stepper("Key", value: state.key.flatMap { $0.isEmpty ? nil : $0 } ?? "—") { store.nudge("key", by: $0) }
            stepper("Tempo", value: state.tempo.flatMap { $0 > 0 ? "\($0) BPM" : nil } ?? "—") { store.nudge("tempo", by: $0) }
            if state.corrected == true {
                Button("Back to the Song's Own") { store.nudge("reset") }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func stepper(_ label: String, value: String, change: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button { change(-1) } label: { Image(systemName: "minus").frame(width: 30, height: 30) }
                .buttonStyle(.glass).buttonBorderShape(.circle)
            Text(value).font(.headline.monospacedDigit()).frame(minWidth: 96)
            Button { change(1) } label: { Image(systemName: "plus").frame(width: 30, height: 30) }
                .buttonStyle(.glass).buttonBorderShape(.circle)
        }
    }

    private func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
