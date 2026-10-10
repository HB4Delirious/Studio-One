import Foundation
import QuartzCore

/// A smooth estimate of the player's position between polls. Asking costs an
/// Apple Event, so it's asked twice a second and a free-running clock fills
/// in; each new reading nudges it back towards the truth rather than snapping,
/// so the lyrics never visibly stutter.
final class PlaybackClock {

    /// Anything larger than this is a seek or a track change, not drift. Snap immediately.
    private let hardSnapThreshold: Double = 0.40
    /// Fraction of the remaining error we absorb per sample. Lower = smoother, slower to converge.
    private let softCorrection: Double = 0.25

    private var anchorPosition: Double = 0
    private var anchorTime: CFTimeInterval = CACurrentMediaTime()

    private(set) var isPlaying: Bool = false

    /// Current estimated position in seconds.
    var position: Double {
        guard isPlaying else { return anchorPosition }
        return anchorPosition + (CACurrentMediaTime() - anchorTime)
    }

    /// Hard reset — use on track change, seek, or first sample.
    func reset(to seconds: Double, playing: Bool) {
        anchorPosition = max(0, seconds)
        anchorTime = CACurrentMediaTime()
        isPlaying = playing
    }

    /// A fresh reading from the player.
    /// - Parameters:
    ///   - sample: the reported position, in seconds
    ///   - sampledAt: `CACurrentMediaTime()` at the middle of the Apple Event round trip
    ///   - playing: whether the player said it was playing
    func ingest(sample: Double, sampledAt: CFTimeInterval, playing: Bool) {
        let now = CACurrentMediaTime()

        // Play/pause edge: no point smoothing across it.
        guard playing == isPlaying else {
            let corrected = playing ? sample + (now - sampledAt) : sample
            reset(to: corrected, playing: playing)
            return
        }

        guard playing else {
            anchorPosition = sample
            anchorTime = now
            return
        }

        // Age the sample forward to "now", then compare against what we predicted.
        let truth = sample + (now - sampledAt)
        let predicted = anchorPosition + (now - anchorTime)
        let error = truth - predicted

        if abs(error) > hardSnapThreshold {
            anchorPosition = truth
        } else {
            anchorPosition = predicted + error * softCorrection
        }
        anchorTime = now
    }
}
