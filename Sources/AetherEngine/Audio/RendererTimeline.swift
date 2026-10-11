import Foundation
import CoreMedia

/// AE#395: the axis the renderers and their synchronizer run on, as distinct from the source axis.
///
/// Everything above the renderers (demuxer, decoders, the host's clock reads, subtitle cues, frame
/// times) stays on the source axis. Only the stamps handed to `AVSampleBufferAudioRenderer`,
/// `AVSampleBufferVideoRenderer` and the synchronizer are moved, by `origin`, so `renderer = source -
/// origin`. Measured on a Belkin AirPlay 2 receiver from tvOS 27.0: one capture, offset to start at
/// 0 and 40002 s, played; offset to 50002 s, and at its original 59670 s, it was silent, renderer
/// rendering and clock at 1.00 throughout. The line sits at 2^31 samples of 48 kHz (44739 s), so a
/// live channel whose PTS carries a broadcast clock never reaches that receiver. A Sonos fed the same
/// sessions played all of them, which is why only the renderer stamps move and nothing else.
///
/// The origin latches at the session's first stamp, from whichever of the clock anchor, the first
/// audio buffer and the first video frame comes first, and holds for the whole session: buffers
/// already queued keep the stamps they were given, so it can never move under them.
final class RendererTimeline: @unchecked Sendable {

    private let lock = NSLock()
    private var _origin: Double?

    /// Source seconds the renderers call zero, nil until the first stamp.
    var origin: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _origin
    }

    /// The renderer stamp for a source time, latching the origin on first use. An invalid or
    /// non-numeric time passes through unchanged and latches nothing.
    func rendererTime(forSource time: CMTime) -> CMTime {
        guard time.isNumeric else { return time }
        let offset = latchedOffset(firstSourceSeconds: CMTimeGetSeconds(time))
        return offset == .zero ? time : CMTimeSubtract(time, offset)
    }

    /// The source time for a renderer stamp or clock reading. Never latches: a read before the first
    /// stamp has no origin to apply.
    func sourceTime(forRenderer time: CMTime) -> CMTime {
        guard time.isNumeric, let origin, origin != 0 else { return time }
        return CMTimeAdd(time, Self.cmTime(origin))
    }

    /// The source time for a renderer stamp in seconds, the counterpart for lines that only log.
    func sourceSeconds(forRenderer seconds: Double) -> Double {
        seconds + (origin ?? 0)
    }

    /// Offset to subtract from every stamp in a sample buffer, latching the origin from its first
    /// presentation stamp.
    func offset(latchingFrom sampleBuffer: CMSampleBuffer) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return origin.map(Self.cmTime) ?? .zero }
        return latchedOffset(firstSourceSeconds: CMTimeGetSeconds(pts))
    }

    private func latchedOffset(firstSourceSeconds seconds: Double) -> CMTime {
        lock.lock()
        let origin: Double
        let latchedNow: Bool
        if let existing = _origin {
            origin = existing
            latchedNow = false
        } else {
            origin = RendererTimelinePolicy.origin(firstSourceSeconds: seconds)
            _origin = origin
            latchedNow = true
        }
        lock.unlock()
        if latchedNow, origin != 0 {
            EngineLog.emit(
                "[AudioOutput] AE#395 renderer timeline origin \(String(format: "%.3f", origin))s "
                + "(first stamp \(String(format: "%.3f", seconds))s, renderers start at "
                + "\(String(format: "%.3f", seconds - origin))s)",
                category: .swPlayback)
        }
        return origin == 0 ? .zero : Self.cmTime(origin)
    }

    static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 90000)
    }
}

/// AE#395: where the renderer axis starts for a session, pure so it can be checked without a renderer.
///
/// A source that starts within `headroomSeconds` of zero keeps origin 0, so an ordinary file plays on
/// exactly the stamps it always had. Anything later starts its renderers at `headroomSeconds`, which
/// leaves that much room for a seek back (a DVR window) before the stamps go negative, and about 9.4
/// hours of forward play before they reach the 44739 s line again.
enum RendererTimelinePolicy {

    static let headroomSeconds: Double = 3 * 3600

    static func origin(firstSourceSeconds seconds: Double) -> Double {
        guard seconds.isFinite, seconds > headroomSeconds else { return 0 }
        return (seconds - headroomSeconds).rounded(.down)
    }
}
