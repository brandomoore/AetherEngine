import Testing
import Foundation
@testable import AetherEngine

/// A live session on the software host starts near the newest media once the source's connect burst
/// has landed, instead of at the burst's first packet, where it would run the whole burst behind the
/// broadcast for the rest of the channel.
@Suite("Software live join placement")
struct SoftwareLiveJoinPlacementTests {

    /// A panel that sends 12 s of media in the first half second, then real time: the join waits
    /// for the burst to calm and starts `leadSeconds` behind the newest media.
    @Test("a connect burst is landed before the start is placed behind the newest media")
    func burstIsLandedThenPlaced() throws {
        var policy = SoftwareLiveJoinPolicy()
        let first = 1000.0
        var decision: SoftwareLiveJoinPolicy.Decision?
        var decidedAt: TimeInterval?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            // 12 s of media over the first 0.5 s, then one second of media per second.
            let newest = now < 0.5 ? first + 24 * now : first + 12 + (now - 0.5)
            decision = policy.observe(firstPts: first, newestPts: newest, at: now)
            if decision != nil { decidedAt = now }
            now += 0.05
        }
        let at = try #require(decidedAt)
        // Calm is judged from 0.3 s on, over a quarter-second window.
        #expect(at >= 0.3 && at <= 1.0, "decided at \(at)s")
        let newestThen = first + 12 + (at - 0.5)
        #expect(decision == .place(targetPts: newestThen - SoftwareLiveJoinPolicy.leadSeconds))
    }

    @Test("a source that delivers in real time starts from its first packet, soon")
    func realTimeSourceStartsFromTheFirstPacket() throws {
        var policy = SoftwareLiveJoinPolicy()
        let first = 50.0
        var decision: SoftwareLiveJoinPolicy.Decision?
        var decidedAt: TimeInterval?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            decision = policy.observe(firstPts: first, newestPts: first + now, at: now)
            if decision != nil { decidedAt = now }
            now += 0.05
        }
        #expect(decision == .fromStart)
        let at = try #require(decidedAt)
        #expect(at >= SoftwareLiveJoinPolicy.minimumSettleSeconds && at <= 0.7, "decided at \(at)s")
    }

    @Test("a burst still landing at the deadline is placed on what has arrived")
    func slowLinkPlacesAtTheDeadline() throws {
        var policy = SoftwareLiveJoinPolicy()
        let first = 0.0
        var decision: SoftwareLiveJoinPolicy.Decision?
        var decidedAt: TimeInterval?
        var now: TimeInterval = 0
        while now <= 3, decision == nil {
            // Six seconds of media per second for as long as it takes: never calm.
            decision = policy.observe(firstPts: first, newestPts: first + 6 * now, at: now)
            if decision != nil { decidedAt = now }
            now += 0.05
        }
        let at = try #require(decidedAt)
        #expect(abs(at - SoftwareLiveJoinPolicy.maximumSettleSeconds) < 0.06, "decided at \(at)s")
        #expect(decision == .place(targetPts: 6 * at - SoftwareLiveJoinPolicy.leadSeconds))
    }

    @Test("a short burst is not worth a later start")
    func shortBurstPlaysFromTheStart() {
        var policy = SoftwareLiveJoinPolicy()
        let first = 10.0
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            // Five seconds of media at once, then real time: a lead of four leaves one to skip.
            decision = policy.observe(firstPts: first, newestPts: first + 5 + now, at: now)
            now += 0.05
        }
        #expect(decision == .fromStart)
    }

    @Test("media whose timestamps run backwards is played from the start")
    func backwardsTimestampsPlayFromTheStart() {
        var policy = SoftwareLiveJoinPolicy()
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            decision = policy.observe(firstPts: 5000, newestPts: 20 + now, at: now)
            now += 0.05
        }
        #expect(decision == .fromStart)
    }
}
