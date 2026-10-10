import SwiftUI

/// Settings › iPhone Remote: the Studio One Remote app — on or off, the code
/// to pair it, and a reset for a lost phone.
struct RemoteSettings: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var server = RequestServer.shared
    @AppStorage(RequestServer.iPhoneRemoteKey) private var enabled = false
    @State private var code: NSImage?
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("iPhone Remote")

            SettingsSection("Studio One Remote", info: "The iPhone app runs the night from your pocket: play, pause, skip and fade, the volume, the key and tempo, Up Next and search. While it's open, the song playing and who's up next stay on the Lock Screen as a Live Activity, with play and skip buttons. It reaches this Mac over the Wi-Fi — found by Bonjour, so a new address after a router restart needs no pairing — whether or not the request line is on, with either player.") {
                Toggle("Let the Studio One Remote app control this Mac", isOn: $enabled)
                    .font(.system(size: 12, design: .rounded))
                if enabled {
                    if let address = server.pairingAddress {
                        HStack(alignment: .top, spacing: 16) {
                            Group {
                                if let code { Image(nsImage: code).interpolation(.none).resizable() } else { Color.white }
                            }
                            .frame(width: 150, height: 150)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("In Studio One Remote, tap Pair and scan this code. (The phone's own camera opens the web remote instead — that works too.)")
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Anyone with this code can control the music: keep it off the big screen.")
                                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Reset the Code…") { confirmReset = true }
                                    .controlSize(.small)
                            }
                        }
                        .task(id: address) { code = RequestServer.qr(for: address, side: 300) }
                        StatusLine("Listening at \(address.host ?? ""):\(address.port.map(String.init) ?? ""), as “\(Host.current().localizedName ?? "this Mac")”.")
                    } else if let failure = server.failure {
                        StatusLine(failure)
                    } else {
                        StatusLine("Opening the port…")
                    }
                }
            }

            SettingsSection("Installing the app", info: "Studio One Remote is in the project's iPhone folder. Xcode installs it on your phone with your Apple ID; with a free account, apps it installs run for seven days, then need installing again the same way.") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Open **iPhone/Studio One Remote.xcodeproj** in Xcode.")
                    Text("2. Plug in your iPhone (or pick it over Wi-Fi), choose it as the destination, press Run.")
                    Text("3. The first time: on the iPhone, Settings › General › VPN & Device Management, trust your Apple ID.")
                    Text("4. Open it, allow Local Network, tap Pair, scan the code above.")
                }
                .font(.system(size: 12))
            }
        }
        .onChange(of: enabled) { _, _ in server.configureRemote(model: model) }
        .confirmationDialog("Reset the remote's code?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { server.resetRemoteCode() }
        } message: {
            Text("Phones paired with the old code — and the web remote's bookmark — stop working until they scan the new one.")
        }
    }
}
