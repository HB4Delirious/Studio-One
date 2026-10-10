import SwiftUI

extension Notification.Name {
    /// Settings, open at Plug-ins: the panel's way to its own settings.
    static let showPluginSettings = Notification.Name("StudioOne.showPluginSettings")
}

/// The lower half of the Controls window's middle: the controls picked in
/// Settings › Plug-ins, a plug-in to a page, as Logic reports them (see
/// `PluginDisplay`) — so there's no need to be in Logic, on top of the
/// plug-in, to see where it's set.
struct PluginDisplayPanel: View {
    @EnvironmentObject private var model: KaraokeModel
    @ObservedObject private var display = PluginDisplay.shared
    @AppStorage(PluginDisplay.panelOpenKey) private var open = true
    /// This song's remembered values, by plug-in and control.
    @State private var recalled: [String: [Int: String]] = [:]
    @State private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if open { content }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, open ? 16 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPane()
        .onAppear(perform: loadRecall)
        .onChange(of: model.track?.trackID) { _, _ in loadRecall() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the plug-in controls" : "Show the plug-in controls")

            Text(headline)
                .font(.system(size: 12))
                .foregroundStyle(display.logicAlert == nil ? Theme.secondary : Theme.sung)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if open, display.phase == .showing, display.shownPlugins.count > 1 {
                pager
            }
            if open, display.phase == .showing, model.track != nil {
                recallMenu
            }
            if case .reading = display.phase {
                ProgressView().controlSize(.small)
            } else if case .failed = display.phase {
                Button("Try Again") { display.retry() }
                    .controlSize(.small)
            }
            Button {
                NotificationCenter.default.post(name: .showPluginSettings, object: nil)
            } label: {
                Image(systemName: "checklist")
            }
            .buttonStyle(.borderless)
            .help("Choose the controls shown here — Settings › Plug-ins")
        }
    }

    private var title: String {
        display.phase == .showing ? display.shownPlugin?.name ?? "Plug-ins" : "Plug-ins"
    }

    private var headline: String {
        if display.logicAlert != nil { return "Paused — Logic has an alert open" }
        switch display.phase {
        case .off:              return "Off — Settings › Plug-ins"
        case .waitingForLogic:  return "Waiting for Logic"
        case .connected:        return display.layouts.isEmpty ? "Connected to Logic" : "Nothing picked to show"
        case .reading(let now): return now
        case .showing:          return recalled.isEmpty ? "Live from Logic" : "Live from Logic · this song's settings beside each"
        case .failed:           return "Not showing"
        }
    }

    /// A plug-in to a page.
    private var pager: some View {
        HStack(spacing: 4) {
            Button { display.showPlugin(forward: false) } label: { Image(systemName: "chevron.left") }
                .help("The plug-in before")
            if let current = display.shownPlugin,
               let index = display.shownPlugins.firstIndex(of: current) {
                Text("\(index + 1)/\(display.shownPlugins.count)")
                    .font(Theme.timecode)
                    .foregroundStyle(Theme.secondary)
            }
            Button { display.showPlugin(forward: true) } label: { Image(systemName: "chevron.right") }
                .help("The next plug-in")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    /// Remember what's shown, for this song.
    private var recallMenu: some View {
        Menu {
            Button(recalled.isEmpty ? "Remember These for This Song" : "Remember Them as They Are Now") { remember() }
            if !recalled.isEmpty {
                Button("Forget for This Song", role: .destructive) { forget() }
            }
        } label: {
            Image(systemName: recalled.isEmpty ? "pin" : "pin.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(recalled.isEmpty
              ? "Remember these values for this song, to dial them back in next time"
              : "This song's settings are shown beside each control")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let alert = display.logicAlert {
            message("Logic has an alert open: “\(alert)”. Until it's closed, Logic ignores every controller — the key, the tempo and the M-BRIO — and Studio One waits.")
        }
        switch display.phase {
        case .showing:
            if let plugin = display.shownPlugin {
                GlassGroup(spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8),
                              alignment: .leading, spacing: 8) {
                        ForEach(display.controls(of: plugin)) { control in
                            ControlTile(control: control, target: recalled[plugin.name]?[control.id],
                                        accent: model.palette.accent)
                        }
                    }
                }
            }
        case .reading:
            message("Reading each plug-in on the locked channel, a page at a time.")
        case .connected:
            if display.layouts.isEmpty {
                message("Read the plug-ins on Topline's channel to choose what shows here.", setup: true,
                        action: ("Read Plug-ins", { display.read() }))
            } else {
                message("Choose which controls appear here.",
                        action: ("Choose Controls…", { NotificationCenter.default.post(name: .showPluginSettings, object: nil) }))
            }
        case .failed(let reason):
            message(reason, setup: true)
        case .off:
            EmptyView()   // The header says so.
        case .waitingForLogic:
            message("Opens by itself when Logic does.", setup: true)
        }
    }

    /// One line of status, and the steps for Logic behind a button.
    private func message(_ text: String, setup: Bool = false,
                         action: (title: String, run: () -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if setup {
                Button("Set Up in Logic…") { showSetup = true }
                    .controlSize(.small)
                    .glassButton()
                    .popover(isPresented: $showSetup, arrowEdge: .top) { setupSteps }
            }
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
                    .glassButton(prominent: true, tint: model.palette.accent)
            }
        }
    }

    private var setupSteps: some View {
        TipSteps(lead: "Once, in Logic Pro › Control Surfaces › Setup…", steps: [
            .init(text: "Mackie Control: both ports **\(display.portName)**. Extender: both **\(display.portName) 2**. Never “Studio One” or “Any”."),
            .init(text: "Untick **Open/Close Plug-in Window** and **Follows Focused View**."),
            .init(text: "Select **Topline's channel** in Logic, then tick **Track Lock**."),
        ])
        .padding(12)
        .frame(width: 380)
    }

    // MARK: - This song's settings

    private func loadRecall() {
        recalled = model.track.map { PluginRecall.values(for: $0.trackID) } ?? [:]
    }

    /// The picked controls of every plug-in on the panel, as Logic shows them now.
    private func remember() {
        guard let id = model.track?.trackID else { return }
        var values: [String: [Int: String]] = [:]
        for plugin in display.shownPlugins {
            let read = display.controls(of: plugin).compactMap { control in
                control.reading.map { (control.id, $0.value) }
            }
            if !read.isEmpty { values[plugin.name] = Dictionary(uniqueKeysWithValues: read) }
        }
        PluginRecall.set(values, for: id)
        recalled = values
        Diagnostics.log("plugin display: remembered \(values.values.map(\.count).reduce(0, +)) values for \(model.track?.name ?? "this song")")
    }

    private func forget() {
        guard let id = model.track?.trackID else { return }
        PluginRecall.set([:], for: id)
        recalled = [:]
    }
}

/// The values remembered for a song from the panel: by track, plug-in name
/// and control position, as Logic showed them. Studio One shows them beside
/// the live ones and sends nothing — the M-BRIO puts them back.
enum PluginRecall {
    private static let key = "pluginDisplay.recall"

    private static var all: [String: [String: [Int: String]]] {
        get {
            UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([String: [String: [Int: String]]].self, from: $0) } ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func values(for trackID: String) -> [String: [Int: String]] {
        all[trackID] ?? [:]
    }

    /// Empty forgets the song.
    static func set(_ values: [String: [Int: String]], for trackID: String) {
        var stored = all
        stored[trackID] = values.isEmpty ? nil : values
        all = stored
    }
}

/// One control: its name, its value as the plug-in shows it, where its knob
/// sits — and, when this song has one remembered, that value beside it. A
/// change flashes the tile, so what the M-BRIO just moved stands out.
private struct ControlTile: View {
    let control: PluginDisplay.Control
    /// This song's remembered value.
    let target: String?
    let accent: Color
    @State private var flash = false
    /// Bumped by each change, so only the latest one's fade ends the flash.
    @State private var flashes = 0

    private var value: String {
        guard let value = control.reading?.value, !value.isEmpty else { return "—" }
        return value
    }

    private var onTarget: Bool { target == control.reading?.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(control.name)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(flash ? accent : Theme.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    if let position = control.reading?.position {
                        Capsule().fill(accent.opacity(0.85))
                            .frame(width: max(4, geo.size.width * position))
                    }
                }
            }
            .frame(height: 3)
            if let target {
                HStack(spacing: 3) {
                    Image(systemName: onTarget ? "checkmark" : "arrow.uturn.backward")
                        .font(.system(size: 8, weight: .bold))
                    Text(target)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(onTarget ? Theme.cue : Theme.sung)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassTile(tint: flash ? accent.opacity(0.55) : nil)
        .overlay(RoundedRectangle(cornerRadius: Chrome.cardRadius, style: .continuous)
            .strokeBorder(border, lineWidth: 1))
        .help(help)
        .onChange(of: control.reading) { old, new in
            // A first reading isn't a change; a new value or knob position is.
            guard old != nil, old != new else { return }
            flashes += 1
            let this = flashes
            withAnimation(.easeOut(duration: 0.12)) { flash = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard flashes == this else { return }
                withAnimation(.easeOut(duration: 0.6)) { flash = false }
            }
        }
    }

    private var border: Color {
        if flash { return accent.opacity(0.9) }
        if target != nil, !onTarget { return Theme.sung.opacity(0.55) }
        return .clear
    }

    private var help: String {
        var lines = ["\(control.name): \(value)"]
        if control.name != control.logicName { lines.append("Logic calls it \(control.logicName)") }
        if let target { lines.append(onTarget ? "As remembered for this song" : "This song's setting: \(target)") }
        return lines.joined(separator: "\n")
    }
}
