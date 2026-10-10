import AppKit
import SwiftUI

/// Settings › Venue: one theme per venue — its name, message, logo, colours,
/// typeface and background on the room's screens — and which is in use.
struct VenueSettings: View {
    @ObservedObject private var venues = VenueThemes.shared
    @State private var pendingRemove: UUID?

    var body: some View {
        let theme = venues.current
        VStack(alignment: .leading, spacing: 18) {
            PaneTitle("Venue")

            SettingsSection("Venues", info: "Each venue keeps its own look on the lyrics, standby and break screens. Pick the one you're at tonight; the Controls window's own look stays as it is.") {
                HStack(spacing: 8) {
                    Picker("Venue", selection: Binding(get: { venues.currentID ?? theme.id },
                                                       set: { venues.use($0) })) {
                        ForEach(venues.themes) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Button("Add Venue") { venues.add() }
                    Button("Remove…") { pendingRemove = theme.id }
                        .disabled(venues.themes.count < 2)
                }
                .controlSize(.small)
                LabelledRow("Theme name:") {
                    TextField("Venue", text: field(\.name)).frame(width: 220)
                }
            }

            SettingsSection("On the screens") {
                LabelledRow("Venue name:") {
                    TextField("Shown instead of Studio One", text: field(\.venueName)).frame(width: 260)
                }
                LabelledRow("Message:") {
                    TextField("Tuesdays from 8 — request with the code!", text: field(\.message)).frame(width: 320)
                }
                LabelledRow("Logo:") {
                    if let logo = venues.logo {
                        Image(nsImage: logo).resizable().scaledToFit().frame(height: 34)
                    }
                    Button(venues.logo == nil ? "Choose…" : "Change…") { chooseLogo() }
                    if venues.logo != nil {
                        Button("Remove") { venues.setLogo(from: nil) }
                    }
                }
                .controlSize(.small)
            }

            SettingsSection("Look") {
                LabelledRow("Sung words:") {
                    ColorPicker("Sung words", selection: colour(\.sungHex), supportsOpacity: false).labelsHidden()
                    Text("Second singer:").font(Theme.label).foregroundStyle(Theme.secondary).padding(.leading, 10)
                    ColorPicker("Second singer", selection: colour(\.cueHex), supportsOpacity: false).labelsHidden()
                }
                LabelledRow("Typeface:") {
                    Picker("Typeface", selection: field(\.typeface)) {
                        ForEach(VenueTheme.Typeface.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                LabelledRow("Background:") {
                    Picker("Background", selection: Binding(
                        get: { theme.backgroundHex != nil },
                        set: { solid in update { $0.backgroundHex = solid ? "0B0A14" : nil } })) {
                        Text("The song's cover").tag(false)
                        Text("One colour").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    if theme.backgroundHex != nil {
                        ColorPicker("Background colour", selection: Binding(
                            get: { Color(hex: theme.backgroundHex ?? "") ?? .black },
                            set: { picked in update { $0.backgroundHex = picked.hex } }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                Button("Back to Studio One's Colours") {
                    update {
                        $0.sungHex = VenueTheme.standard.sungHex
                        $0.cueHex = VenueTheme.standard.cueHex
                        $0.typeface = .rounded
                        $0.backgroundHex = nil
                    }
                }
                .controlSize(.small)
            }

            SettingsSection("Preview") {
                VenuePreview()
                    .frame(width: 512, height: 288)
                    .clipShape(RoundedRectangle(cornerRadius: Chrome.cardRadius, style: .continuous))
            }
        }
        .confirmationDialog("Remove this venue's theme?", isPresented: Binding(
            get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = pendingRemove { venues.remove(id) }
                pendingRemove = nil
            }
        } message: {
            Text("“\(theme.name)”, with its logo. This can't be undone.")
        }
    }

    private func update(_ change: (inout VenueTheme) -> Void) {
        var theme = venues.current
        change(&theme)
        venues.update(theme)
    }

    private func field<Value>(_ path: WritableKeyPath<VenueTheme, Value>) -> Binding<Value> {
        Binding(get: { venues.current[keyPath: path] },
                set: { value in update { $0[keyPath: path] = value } })
    }

    private func colour(_ path: WritableKeyPath<VenueTheme, String>) -> Binding<Color> {
        Binding(get: { Color(hex: venues.current[keyPath: path]) ?? .white },
                set: { picked in update { $0[keyPath: path] = picked.hex } })
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "A logo for the standby and break screens — a PNG with a transparent background looks best."
        if panel.runModal() == .OK, let url = panel.url { venues.setLogo(from: url) }
    }
}

/// The standby screen and a sample line, in the theme as set.
private struct VenuePreview: View {
    @ObservedObject private var venues = VenueThemes.shared

    var body: some View {
        let theme = venues.current
        ZStack {
            VenueLook.current.background ?? Theme.backdrop
            VStack(spacing: 12) {
                if let logo = venues.logo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(maxWidth: 180, maxHeight: 64)
                }
                Text(theme.venueName.isEmpty ? "Studio One" : theme.venueName)
                    .font(.system(size: 30, weight: .heavy, design: Theme.stageDesign))
                    .foregroundStyle(.white)
                if !theme.message.isEmpty {
                    Text(theme.message)
                        .font(.system(size: 14, weight: .bold, design: Theme.stageDesign))
                        .foregroundStyle(Theme.sung)
                }
                HStack(spacing: 0) {
                    Text("Sing it ").foregroundStyle(Theme.sung)
                    Text("loud tonight").foregroundStyle(Theme.upcoming)
                }
                .font(Theme.lyric(22, active: true))
                .padding(.top, 10)
                Text("and the second part").font(Theme.lyric(16, active: false)).foregroundStyle(Theme.cue)
            }
            .padding(20)
        }
    }
}
