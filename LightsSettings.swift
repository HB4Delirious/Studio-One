import SwiftUI

/// Settings › Lights: the DMX interface, the show's master level, the
/// fixtures and their addresses, and test colours to check each one.
struct LightsSettings: View {
    @ObservedObject private var show = LightShow.shared
    @AppStorage(LightShow.enabledKey) private var enabled = false
    @AppStorage(LightShow.portKey) private var port = ""
    @AppStorage(LightShow.interfaceKey) private var interface: DMX.Interface = .enttecPro
    @AppStorage(LightShow.masterKey) private var master = 100.0
    @AppStorage(LightShow.blackoutKey) private var blackout = false
    @AppStorage(LightShow.pulseKey) private var pulse = true
    @State private var ports: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Lights")

            SettingsSection("DMX", info: "Studio One runs the room's lights through a USB DMX interface. DMX USB Pro covers the ENTTEC DMX USB Pro and the many interfaces that speak its protocol (DMXking ultraDMX, Eurolite USB-DMX512 Pro…); Open DMX covers the ENTTEC Open DMX USB and plain FTDI cables, which leave the timing to the Mac. If the interface isn't listed, install its maker's FTDI driver, plug it in and press Refresh.") {
                Toggle("Run the lights", isOn: $enabled)
                    .font(.system(size: 12, design: .rounded))
                LabelledRow("Interface:") {
                    Picker("Interface", selection: $port) {
                        Text("None").tag("")
                        ForEach(ports, id: \.self) { Text(name($0)).tag($0) }
                        if !port.isEmpty, !ports.contains(port) {
                            Text("\(name(port)) (not plugged in)").tag(port)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Refresh") { ports = DMX.availablePorts() }
                        .controlSize(.small)
                }
                LabelledRow("Type:") {
                    Picker("Type", selection: $interface) {
                        ForEach(DMX.Interface.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                if enabled { StatusLine(statusText) }
            }

            SettingsSection("The show", info: "While someone sings, the lights stay low in the colours of the song's cover — low enough for the screen to read — pulsing on the beat when the song's tempo is known, and turning to the next colour every four bars. A break brings them up bright; while the applause meter listens they follow the cheer. House music breathes gently in the last song's colours; with nothing playing they drift slowly round the colours.") {
                LabelledRow("Master:") {
                    Slider(value: $master, in: 0...100, step: 5).frame(width: 200)
                    Text("\(Int(master))%").font(Theme.timecode).foregroundStyle(Theme.secondary)
                }
                Toggle("Pulse on the beat", isOn: $pulse)
                    .font(.system(size: 12, design: .rounded))
                Toggle("Blackout (Playback › Blackout, ⇧⌘B)", isOn: $blackout)
                    .font(.system(size: 12, design: .rounded))
            }

            SettingsSection("Fixtures", info: "Each light's DMX address — its first channel, as set on the fixture — and what its channels are, in order. Most fixtures have several channel modes; pick the one that matches one of these (often called 3CH, 4CH or 5CH in the fixture's menu). Find lights only that fixture, in white, for six seconds.") {
                if show.fixtures.isEmpty {
                    Text("No fixtures yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                let overlaps = DMX.overlaps(show.fixtures)
                ForEach(show.fixtures) { fixture in
                    VStack(alignment: .leading, spacing: 3) {
                        FixtureRow(fixture: binding(fixture), light: show.preview[fixture.id])
                        if let other = overlaps[fixture.id] {
                            Text("Shares channels with “\(other)”.")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                }
                Button("Add Fixture") { add() }
                    .controlSize(.small)
            }

            SettingsSection("Test") {
                HStack(spacing: 8) {
                    ForEach(Self.tests, id: \.name) { test in
                        Button {
                            show.test(test.light)
                        } label: {
                            Label {
                                Text(test.name)
                            } icon: {
                                Circle().fill(swatch(test.light)).frame(width: 9, height: 9)
                            }
                        }
                    }
                    if show.testing != nil {
                        Button("Back to the Show") { show.test(nil) }
                    }
                }
                .controlSize(.small)
                .disabled(!enabled)
                Text(enabled ? "Each colour holds for six seconds, at full, over Master and Blackout."
                             : "Turn on Run the lights to test them.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        .onAppear {
            ports = DMX.availablePorts()
            show.previewing += 1
        }
        .onDisappear { show.previewing -= 1 }
        .onChange(of: enabled) { _, _ in show.configure() }
        .onChange(of: port) { _, _ in show.configure() }
        .onChange(of: interface) { _, _ in show.configure() }
    }

    private static let tests: [(name: String, light: DMX.Light)] = [
        ("Red", DMX.Light(red: 1, green: 0, blue: 0, level: 1)),
        ("Green", DMX.Light(red: 0, green: 1, blue: 0, level: 1)),
        ("Blue", DMX.Light(red: 0, green: 0, blue: 1, level: 1)),
        ("White", DMX.Light(red: 1, green: 1, blue: 1, level: 1)),
    ]

    private var statusText: String {
        switch show.status {
        case .off:                 return "Off."
        case .noPort:              return "Choose the interface above."
        case .sending(let path):   return "Sending to \(name(path)), thirty times a second."
        case .failed(let message): return "Can't use \(port.isEmpty ? "the interface" : name(port)): \(message). Trying again…"
        }
    }

    /// "usbserial-EN123456", without /dev/cu.
    private func name(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "").replacingOccurrences(of: "cu.", with: "")
    }

    /// By ID rather than position, so a row removed mid-edit can't write
    /// into its neighbour.
    private func binding(_ fixture: DMX.Fixture) -> Binding<DMX.Fixture> {
        Binding(get: { show.fixtures.first { $0.id == fixture.id } ?? fixture },
                set: { changed in
                    if let index = show.fixtures.firstIndex(where: { $0.id == fixture.id }) { show.fixtures[index] = changed }
                })
    }

    /// The next free address after the last fixture.
    private func add() {
        let next = (show.fixtures.map(\.lastChannel).max() ?? 0) + 1
        show.fixtures.append(DMX.Fixture(name: "Light \(show.fixtures.count + 1)",
                                         address: min(DMX.universe, next), kind: .rgb))
    }
}

/// One fixture: what it's showing, its name, address and channels.
private struct FixtureRow: View {
    @Binding var fixture: DMX.Fixture
    let light: DMX.Light?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(swatch(light ?? .off))
                .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                .frame(width: 16, height: 16)
                .help("What it's showing now")
            TextField("Name", text: $fixture.name).frame(width: 130)
            Text("Address").font(Theme.label).foregroundStyle(Theme.secondary)
            TextField("1", value: Binding(get: { fixture.address },
                                          set: { fixture.address = min(DMX.universe, max(1, $0)) }),
                      format: .number.grouping(.never))
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
            Picker("Channels", selection: $fixture.kind) {
                ForEach(DMX.Kind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            Text(fixture.kind.channels == 1 ? "Ch \(fixture.address)" : "Ch \(fixture.address)–\(fixture.lastChannel)")
                .font(Theme.timecode).foregroundStyle(Theme.secondary)
                .frame(width: 64, alignment: .leading)
            Spacer(minLength: 0)
            Button("Find") { LightShow.shared.test(DMX.Light(red: 1, green: 1, blue: 1, level: 1), only: fixture.id) }
            Button {
                LightShow.shared.fixtures.removeAll { $0.id == fixture.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this fixture")
        }
        .controlSize(.small)
    }
}

/// How a light looks, for the swatches.
private func swatch(_ light: DMX.Light) -> Color {
    let level = 0.15 + 0.85 * light.level
    return Color(red: light.red * level, green: light.green * level, blue: light.blue * level)
}
