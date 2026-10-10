import SwiftUI

@main
struct RemoteApp: App {
    @Environment(\.scenePhase) private var phase
    private let store = RemoteStore.shared

    init() {
        // The Lock Screen's buttons run here, in the app: afterwards, the
        // Live Activity shows what they did.
        RemoteAPI.afterCommand = {
            try? await Task.sleep(for: .milliseconds(500))
            await RemoteStore.shared.refresh()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.pink)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, phase in
            if phase == .active { store.startPolling() } else if phase == .background { store.stopPolling() }
        }
    }
}

enum Theme {
    static let pink = Color(red: 0.91, green: 0.22, blue: 0.56)
    static let violet = Color(red: 0.36, green: 0.23, blue: 0.91)
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.08)
    static let teal = Color(red: 0.28, green: 0.85, blue: 0.75)
}

struct RootView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        if store.pairing == nil {
            PairView()
        } else {
            TabView {
                Tab("Now", systemImage: "music.mic") { NowPlayingView() }
                Tab("Up Next", systemImage: "list.bullet") { UpNextView() }
                Tab(role: .search) { SearchView() }
            }
        }
    }
}
