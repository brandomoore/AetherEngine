import Foundation

/// Small presentation-associated seam history. Overflow fails closed until reset.
final class ActivePictureTimeline: @unchecked Sendable {
    private static let sequence = FrameTimeSequence()
    private let lock = NSLock()
    private var base = ActivePictureTimeline.sequence.next()
    private var seams: [(time: Double, generation: UInt64)] = []
    private var overflow = false

    func reset() {
        lock.lock(); defer { lock.unlock() }
        base = Self.sequence.next()
        seams.removeAll(keepingCapacity: true)
        overflow = false
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        base = Self.sequence.next()
        seams = seams.map { ($0.time, Self.sequence.next()) }
    }

    func markSeam(at time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard time.isFinite else { overflow = true; return }
        seams.removeAll { $0.time >= time }
        guard seams.count < 64 else { overflow = true; return }
        seams.append((time, Self.sequence.next()))
    }

    func generation(at time: Double) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard !overflow, time.isFinite else { return nil }
        return seams.last(where: { $0.time <= time })?.generation ?? base
    }
}
