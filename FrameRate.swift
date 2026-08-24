import AppKit

/// Redraw rate for the animated surfaces — lyrics, background, scrubber.
///
/// `TimelineView(.animation(minimumInterval:))` sets a floor on the gap between
/// updates, not the rate itself; the display link still decides when to draw. So
/// asking for 1/120 permits up to 120fps on a display that can do it, and simply
/// draws slower on one that can't.
enum FrameRate {

    static let defaultsKey = "targetFPS"
    static let minimum: Double = 60

    /// The best any attached display can deliver.
    ///
    /// Deliberately not `NSScreen.main`, which is the screen holding the *key*
    /// window — with the lyrics on a 120 Hz TV and the controls focused on a
    /// 60 Hz laptop, that reports 60 and the higher rate can never be chosen.
    static var displayMaximum: Double {
        Double(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
    }

    /// Upper end of the slider. Always at least 120 so the choice exists before
    /// a capable display is plugged in — asking for more than the panel can show
    /// simply results in the panel's rate, it isn't an error.
    static var selectableMaximum: Double { Swift.max(120, displayMaximum) }

    /// Not clamped to the display. `minimumInterval` is a floor on redraw
    /// spacing; the display link still decides the real rate, so requesting 120
    /// on a 60 Hz screen just yields 60 — and yields 120 the moment a 120 Hz
    /// screen is connected, with no settings change needed.
    static func interval(for requested: Double) -> Double {
        1.0 / Swift.min(Swift.max(minimum, requested), 240)
    }
}
