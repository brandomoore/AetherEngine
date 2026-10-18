import Foundation

/// The lowest presentation time still to come, for a renderer that is handed frames in decode order.
///
/// `AVSampleBufferVideoRenderer` sorts the frames it is given by presentation time on its own, but a
/// frame that arrives in decode order cannot be shown until the queue knows nothing earlier is still
/// on its way. An app tells it through `presentationTimeExpectation = .minimumUpcoming(_:)`. Without that bound a
/// Mac test dropped 25 to 50% of frames for hierarchical-B GOPs of 8 to 16, and with it none.
///
/// The bound is the first gap in the frame grid. `frontier` is the newest timestamp below which
/// every slot has been handed over; frames past it wait in `ahead` until the slots before them fill.
/// The floor sits half a frame past the frontier, below the next slot even when a container rounds
/// its timestamps to the millisecond. A slot the clock has already passed is given up, so a frame
/// that never comes (a decode failure, a gap in the stream) cannot hold the floor down for good.
///
/// Pure: the renderer owns one, guards it with its lock and feeds it the clock.
struct PresentationFloor {

    /// Seconds per frame.
    let interval: Double

    /// Newest timestamp with every earlier slot handed over; nil until the first frame or a start.
    private(set) var frontier: Double?
    /// Handed-over timestamps past the frontier, ascending.
    private(set) var ahead: [Double] = []
    /// What the renderer has been promised. Never moves down between resets.
    private(set) var floor: Double = -.infinity

    /// How far past the frontier the clock may be and still give up slots, in seconds.
    static let maxClockGap: Double = 1
    /// Most frames `ahead` may hold before the slot under its head is given up without the clock.
    /// Far past any GOP's reordering, so it only fires when a hole has outlived `maxClockGap`.
    static let maxAhead = 64

    init(interval: Double) {
        self.interval = interval
    }

    struct Step: Equatable {
        /// Timestamps that joined the frontier with this frame, in display order: the cadence the
        /// renderer will actually show, for the spacing diagnostic.
        var contiguous: [Double] = []
        /// The new floor, when it moved; nil when the promise is unchanged.
        var raisedFloor: Double?
        /// The frame arrived below a floor already promised. It is still handed over, and the
        /// renderer may drop it.
        var belowFloor = false
    }

    /// Forgets everything (a flush). `start` is the lowest timestamp that can still arrive, when the
    /// caller knows it: after a seek the first frame past the skip threshold need not be the lowest
    /// one to come, since B-frames below it arrive after it in decode order, so the frontier starts
    /// just below the threshold rather than at that frame. Half a frame below, not a whole one: a seek
    /// target is not on the frame grid, and from a whole frame below the first frame past it joins
    /// only when it lies within half a frame of the target. Otherwise the frontier waited for the clock,
    /// which a preroll holds still (#774), so about every second seek ran into the preroll timeout.
    /// The floor this seeds is the threshold itself, which no admitted frame is below.
    mutating func reset(start: Double? = nil) {
        frontier = start.map { $0 - 0.5 * interval }
        ahead.removeAll()
        floor = -.infinity
    }

    /// Records a frame handed to the renderer. `clockSeconds` is the playback clock on the same axis,
    /// nil while it is not running.
    mutating func record(_ pts: Double, clockSeconds: Double?) -> Step {
        var step = Step()
        var f = frontier ?? (pts - interval)
        if pts < floor {
            step.belowFloor = true
        } else if pts > f {
            let i = ahead.firstIndex(where: { $0 > pts }) ?? ahead.endIndex
            ahead.insert(pts, at: i)
        }
        // A clock more than `maxClockGap` past the frontier is not this stream's: a renderer not yet
        // attached to its synchronizer runs on host time.
        let clock = clockSeconds.flatMap { $0.isFinite && $0 - f <= Self.maxClockGap ? $0 : nil }
        // A hole the clock can no longer reach (decode fell more than `maxClockGap` behind) would hold
        // the floor until the next flush and grow `ahead` by a frame each time.
        if ahead.count > Self.maxAhead, let head = ahead.first {
            f = max(f, head - interval)
        }
        while true {
            if let next = ahead.first, next < f + 1.5 * interval {
                step.contiguous.append(next)
                f = max(f, next)
                ahead.removeFirst()
            } else if let clock, f + 1.5 * interval <= clock {
                // A slot the clock has passed: anything still owed there is late anyway. The step
                // leaves the floor at or below the clock, since after an off-grid seek the frontier
                // is not on the stream's grid and a real slot can sit just past the clock.
                f += interval
            } else {
                break
            }
        }
        frontier = f
        let candidate = f + 0.5 * interval
        if candidate > floor {
            floor = candidate
            step.raisedFloor = candidate
        }
        return step
    }
}
