import Foundation
import CoreGraphics

/// A resident still's measured timestamp, on the caller's timeline. Refinement
/// means target-directed decoding succeeded, not that requested and actual PTS coincide.
// CGImage is immutable; all other stored properties are immutable Sendable values.
public struct ScrubFrame: @unchecked Sendable {
    public let image: CGImage
    public let actualSeconds: Double
    public let refined: Bool
    public let validRange: Range<Double>?
    public init(image: CGImage, actualSeconds: Double, refined: Bool, validRange: Range<Double>? = nil) {
        self.image = image; self.actualSeconds = actualSeconds; self.refined = refined
        self.validRange = validRange
    }
}

/// Raw PTS is restored with the normalization recorded for the bytes' epoch,
/// then folded through the same source origin as the published playhead.
enum ScrubSegmentTime {
    static func displayTime(rawPTS: Double, carriedOffset: Double, displayOrigin: Double) -> Double? {
        guard rawPTS.isFinite, carriedOffset.isFinite, displayOrigin.isFinite else { return nil }
        return rawPTS + carriedOffset - displayOrigin
    }
}

/// Which extraction mode produced (or is requested for) a frame.
///
/// - `thumbnail`: nearest keyframe, no forward decode, downscaled. Cheap; scrub/Recents.
/// - `snapshot`: frame-accurate (decode forward to exact PTS), full/requested res; stills.
public enum FrameMode: Sendable, Hashable {
    case thumbnail
    case snapshot
}
