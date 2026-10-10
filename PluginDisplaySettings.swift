import SwiftUI

/// Settings › Plug-ins: the plug-ins on the channel Logic has locked, read
/// from Logic, which of their controls the Controls window shows, in what
/// order and under what names — and the key check.
struct PluginDisplaySettings: View {
    @ObservedObject private var display = PluginDisplay.shared
    @AppStorage(PluginDisplay.Role.panel.enabledKey) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Plug-ins")

            SettingsSection("") {
                Toggle("Show plug-in controls in the Controls window", isOn: $enabled)
                    .font(.system(size: 12, design: .rounded))
                    .onChange(of: enabled) { _, on in
                        on ? display.start() : display.stop()
                    }
                    .info("Studio One appears to Logic as a Mackie Control and Extender, “\(display.portName)” and “\(display.portName) 2”. Logic shows a Mackie Control sixteen of a plug-in's controls at a time — a page — with their values as they change, from the M-BRIO, the mouse, automation or a preset. Studio One sends the plug-ins nothing; it presses only the surface's own buttons, to open them and turn their pages.\n\nOnce, in Logic Pro › Control Surfaces › Setup…: the Mackie Control's ports are “\(display.portName)”, the Extender's “\(display.portName) 2” — never “Studio One”, which carries the key and tempo, nor “Any”. Untick Open/Close Plug-in Window, or Logic opens the plug-in each time; untick Follows Focused View; select Topline's channel in Logic, then tick Track Lock, so clicking other tracks doesn't move the display. Then read the plug-ins here, and tick what to show.\n\nControls on one of Logic's pages are live. Picks from more than one page are taken in turn — a moment on each, longer on one that's moving — so each is at most a second or two behind. Read again after adding, removing or moving a plug-in on the channel; what's ticked, its order and its names are kept.")
                if enabled {
                HStack(spacing: 10) {
                    Button(display.layouts.isEmpty ? "Read the Plug-ins from Logic" : "Read Again") { display.read() }
                        .disabled(!Self.canRead(display.phase))
                        .help("Reads every control of each plug-in on the channel Logic has locked")
                    if case .reading = display.phase {
                        ProgressView().controlSize(.small)
                    }
                    StatusLine(status)
                }
                .controlSize(.small)
                if display.layouts.isEmpty {
                    Text("Nothing read yet: read the plug-ins, then tick what to show.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.secondary)
                }
                }
            }

            if enabled {
                ForEach(display.layouts) { PluginPicker(layout: $0) }
            }

            MicMeterSettings()
            KeyCheckSettings()
        }
    }

    static func canRead(_ phase: PluginDisplay.Phase) -> Bool {
        switch phase {
        case .connected, .showing, .failed: return true
        case .off, .waitingForLogic, .reading: return false
        }
    }

    private var status: String {
        if display.logicAlert != nil { return "Paused: Logic has an alert open." }
        switch display.phase {
        case .off:              return "Starting…"
        case .waitingForLogic:  return "Waiting for Logic — open it, and it connects by itself."
        case .connected:        return display.layouts.isEmpty ? "Connected to Logic." : "Connected to Logic — nothing ticked yet."
        case .reading(let now): return now
        case .showing:          return "Showing in the Controls window."
        case .failed(let why):  return why
        }
    }
}

/// One plug-in: what the panel shows, in order and by name, then every
/// control to tick, page by page as Logic shows them.
private struct PluginPicker: View {
    let layout: PluginDisplay.Layout
    @ObservedObject private var display = PluginDisplay.shared

    private var named: [Int] {
        layout.controls.indices.filter { !layout.controls[$0].isEmpty }
    }

    private var shown: [Int] {
        (display.picks[layout.name] ?? []).filter { $0 < layout.controls.count }
    }

    var body: some View {
        SettingsSection(layout.name) {
            HStack(spacing: 10) {
                Text("Insert \(layout.slot) · \(shown.count) of \(named.count) shown")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("All") { display.pickAll(true, in: layout) }
                Button("None") { display.pickAll(false, in: layout) }
                    .disabled(shown.isEmpty)
            }
            .controlSize(.small)

            if !shown.isEmpty { shownList }

            ForEach(1...layout.pageCount, id: \.self) { page in
                // Logic's page shows each sixteen together; its last page,
                // filled from the end, also some of the page before.
                let indices = named.filter { $0 / layout.pageSize + 1 == page }
                if !indices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if layout.pageCount > 1 {
                            Text("Page \(page)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 8, alignment: .leading)],
                                  alignment: .leading, spacing: 5) {
                            ForEach(indices, id: \.self) { index in
                                pick(index)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// What the panel shows, in its order: drag to reorder, type to rename.
    private var shownList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SHOWN, IN ORDER — drag to reorder, type a name to rename")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondary)
            List {
                ForEach(shown, id: \.self) { index in
                    ShownRow(layout: layout, index: index)
                }
                .onMove { display.movePicks(in: layout, from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(shown.count) * 34 + 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hairline))
        }
        .padding(.bottom, 4)
    }

    /// The control's short name, and its value when Logic has shown it.
    private func pick(_ index: Int) -> some View {
        Toggle(isOn: Binding(get: { display.isPicked(index, in: layout) },
                             set: { display.setPicked($0, index, in: layout) })) {
            HStack(spacing: 5) {
                Text(display.label(index, in: layout))
                    .font(.system(size: 12, design: .rounded))
                    .lineLimit(1)
                if let value = display.readings[layout.name]?[index]?.value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .help("Logic calls it \(layout.controls[index])")
    }
}

/// One shown control: its name on the panel (blank for Logic's own), Logic's
/// name, its value, and a way out.
private struct ShownRow: View {
    let layout: PluginDisplay.Layout
    let index: Int
    @ObservedObject private var display = PluginDisplay.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
            TextField(layout.controls[index], text: Binding(
                get: { display.labels[layout.name]?[index] ?? "" },
                set: { display.setLabel($0, index, in: layout) }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .rounded))
                .frame(width: 170)
            Text(layout.controls[index])
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .frame(width: 64, alignment: .leading)
            Text(display.readings[layout.name]?[index]?.value ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                display.setPicked(false, index, in: layout)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondary)
            .help("Stop showing it")
        }
        .frame(height: 26)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// The key check: a second surface, in a group of its own, that keeps
/// MetaTune on Mic 1's channel in view and holds it to each key sent.
private struct KeyCheckSettings: View {
    @ObservedObject private var check = PluginDisplay.check
    @ObservedObject private var keyCheck = KeyCheck.shared
    @AppStorage(PluginDisplay.Role.check.enabledKey) private var enabled = false

    var body: some View {
        SettingsSection("Key check", info: "Logic tells Studio One nothing about an assignment, but it tells a Mackie Control what a plug-in is set to. The check reads MetaTune's twelve switches on Mic 1's channel and holds them to the key Studio One sent: a tick beside KEY when it landed, a warning naming what MetaTune shows when it didn't. Walk the Switches on Mic 1 is checked a step at a time, so a switch learned wrongly shows up by name in the log.") {
            Toggle("Check that each key lands in MetaTune on Mic 1", isOn: $enabled)
                .font(.system(size: 12, design: .rounded))
                .onChange(of: enabled) { _, on in
                    on ? check.start() : check.stop()
                }
            if enabled {
                HStack(spacing: 10) {
                    Button(check.layouts.isEmpty ? "Read Mic 1's Plug-ins" : "Read Again") { check.read() }
                        .disabled(!PluginDisplaySettings.canRead(check.phase))
                    if case .reading = check.phase {
                        ProgressView().controlSize(.small)
                    }
                    StatusLine(status)
                }
                .controlSize(.small)
                TipSteps(lead: "Once, in Logic:", steps: [
                    .init(text: "Studio One now offers Logic a second Mackie Control and Extender, **\(check.portName)** and **\(check.portName) 2**. In **Logic Pro › Control Surfaces › Setup…**, if they aren't there, choose **New › Scan All Models**, and click OK on the alert it ends with straight away: Logic ignores every controller while it's open."),
                    .init(text: "**Drag the two new units down into the empty space below** the others, making a group of their own. In the same group as the Studio One Display units, they'd split Topline's page across all four."),
                    .init(text: "Click each new unit and check its ports: **\(check.portName)** for the Mackie Control, **\(check.portName) 2** for the Extender."),
                    .init(text: "With the new group's settings showing: untick **Open/Close Plug-in Window** and **Follows Focused View**, select **Mic 1's channel** in Logic, then tick **Track Lock**."),
                    .init(text: "Studio One reads Mic 1's plug-ins by itself and keeps MetaTune's switches in view; the check shows beside KEY in the Controls window."),
                ])
            }
        }
    }

    private var status: String {
        if check.logicAlert != nil { return "Paused: Logic has an alert open." }
        switch keyCheck.status {
        case .off:                          return "Off."
        case .notReady(let why):            return why
        case .waiting(let key):             return "Sent \(key); checking…"
        case .landed(let key):              return "MetaTune on Mic 1 shows \(key)."
        case .missed(let expected, let shows): return "Sent \(expected), but MetaTune on Mic 1 shows \(shows): the key didn't land."
        case .bypassed:                     return "MetaTune on Mic 1 is bypassed."
        }
    }
}
