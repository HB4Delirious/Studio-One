import SwiftUI

/// The Controls window's chrome, the macOS 26+ way: panes and bars float as
/// Liquid Glass over the artwork-tinted backdrop, with a gutter between them.
/// Before macOS 26 the same shapes fall back to a frosted material with a
/// hairline, so nothing moves.
enum Chrome {
    /// Between floating panes, and from the window's edge.
    static let gutter: CGFloat = 10
    /// A pane: sidebar, now playing, the plug-in panel.
    static let paneRadius: CGFloat = 18
    /// A card or tile inside a pane, concentric with it.
    static let cardRadius: CGFloat = 12
    /// A row's highlight inside a card.
    static let rowRadius: CGFloat = 8
}

extension View {
    /// A floating glass pane, optionally tinted (an alert's orange).
    @ViewBuilder
    func glassPane(cornerRadius: CGFloat = Chrome.paneRadius, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.18)) }
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
        }
    }

    /// A small piece of glass in a pane — a tile, a chip — that can light up.
    @ViewBuilder
    func glassTile(cornerRadius: CGFloat = Chrome.cardRadius, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint?.opacity(0.22) ?? Color.white.opacity(0.06)))
        }
    }

    /// A glass button; prominent ones take the tint (the cover's accent).
    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent).tint(tint)
            } else {
                buttonStyle(.glass).tint(tint)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).tint(tint)
        } else {
            buttonStyle(.bordered).tint(tint)
        }
    }
}

/// Glass shapes near each other blend into one another on macOS 26+, as a
/// group; before it, just the content.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
