import SwiftUI

/// A setting's explanation, behind a small ⓘ at the end of its row, rather
/// than a "Details" line of its own under every setting.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("About this setting")
        .accessibilityLabel("About this setting")
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .frame(width: 360)
            .frame(maxHeight: 440)
        }
    }
}

extension View {
    /// The row, then its ⓘ. Put after `.disabled`, so the explanation stays
    /// readable while the setting can't be used.
    func info(_ text: String) -> some View {
        HStack(spacing: 6) {
            self
            InfoButton(text)
        }
    }
}

/// The Show/Hide button on its own, for text that unfolds away from it —
/// a tip beside one button in a row, with the steps below the row.
struct InfoToggle: View {
    @Binding var open: Bool
    var noun = "info"
    var icon = "info.circle"
    var help = "Show the explanation for this section"

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
        } label: {
            Label(open ? "Hide \(title)" : title.capitalized,
                  systemImage: open ? "chevron.up" : icon)
                .font(.system(size: 11))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondary)
        .help(open ? "Fold this away" : help)
    }

    /// "Details" for an explanation, else what it is ("tip").
    private var title: String { noun == "info" ? "details" : noun }
}

/// Numbered steps to follow in another app, so they stay readable while
/// you work there. Each step is inline Markdown — **bold** for what to
/// click, `code` for what to type, links — and a step can offer its text
/// to copy, for a field that's easy to mistype.
struct TipSteps: View {
    struct Step {
        let text: String
        var copy: String?
    }

    let lead: String
    let steps: [Step]
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(lead)
                .foregroundStyle(Theme.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.markdown(step.text))
                            .fixedSize(horizontal: false, vertical: true)
                        if let text = step.copy {
                            copyButton(text)
                        }
                    }
                }
            }
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(.white.opacity(0.85))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.hairline))
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copied == text { copied = nil }
            }
        } label: {
            Label(copied == text ? "Copied" : "Copy \(text)",
                  systemImage: copied == text ? "checkmark.circle" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.cue)
        .help("Copy it to the clipboard")
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// MARK: - Pane layout

/// A settings pane's heading.
struct PaneTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 24, weight: .bold))
    }
}

/// A titled group within a pane: its title above, its settings in a card,
/// as System Settings groups them. `divided` is kept for the callers; cards
/// set groups apart by themselves.
struct SettingsSection<Content: View>: View {
    let title: String
    let divided: Bool
    /// What the whole group is for, behind an ⓘ beside its title.
    let info: String?
    let content: Content

    init(_ title: String, divided: Bool = true, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.divided = divided
        self.info = info
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !title.isEmpty {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    if let info { InfoButton(info) }
                }
                .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Chrome.cardRadius, style: .continuous)
                .fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: Chrome.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07)))
        }
    }
}

/// "Label:" then its control, flush left — the way every row in Settings reads.
struct LabelledRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.label).foregroundStyle(Theme.secondary)
            content
        }
    }
}

/// What the plug-ins or Logic should be showing now — read against the rig,
/// so brighter than the explanations around it.
struct StatusLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Logic assignments learned from a whole key change, which swallow that key
/// (see `LogicAssignments`).
struct SwallowerWarnings: View {
    let swallowers: [LogicAssignments.Swallower]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(swallowers, id: \.label) { swallower in
                Label(swallower.warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.sung)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Read from Logic's settings as it last saved them; Logic saves them as it quits.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.secondary)
        }
    }
}
