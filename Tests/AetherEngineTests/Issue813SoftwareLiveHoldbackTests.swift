import Testing
import Foundation
@testable import AetherEngine

/// AE#813: a software live session over an HLS ingest holds back by the unit its source delivers in.
///
/// Reported on an iPhone against 10 s segments: the join placed the picture 4 s behind the newest
/// media, the 4 s ran dry before the next segment landed, and the rebuffer resumed at 2 s of audio,
/// which the late segment supplied at once, so the stall repeated on every segment.
@Suite("A software live session holds back by its source's delivery unit (AE#813)")
struct Issue813SoftwareLiveHoldbackTests {

    // MARK: - The holdback

    @Test("a continuous source keeps the values it had", arguments: [nil, 0, -3, Double.nan])
    func continuousSourceIsUnchanged(unit: Double?) {
        let h = SoftwareLiveHoldback(deliveryUnitSeconds: unit)
        #expect(h == .continuous)
        #expect(h.joinLeadSeconds == SoftwareLiveJoinPolicy.leadSeconds)
        #expect(h.landingHoldbackSeconds == AudioLookaheadPolicy.rebufferResumeLeadSeconds)
        #expect(h.resumeCushionSeconds == nil)
        #expect(h.edgeHoldbackSeconds == nil)
    }

    @Test("the join lead follows the segment length",
          arguments: [(2.0, 4.0), (6.0, 10.0), (10.0, 16.0), (40.0, 45.0)])
    func joinLeadTable(unit: Double, lead: Double) {
        #expect(SoftwareLiveHoldback(deliveryUnitSeconds: unit).joinLeadSeconds == lead)
    }

    @Test("a segmented source resumes past one unit, lands and counts the edge at the join lead")
    func segmentedSourceValues() {
        let h = SoftwareLiveHoldback(deliveryUnitSeconds: 10)
        #expect(h.resumeCushionSeconds == 12)
        #expect(h.landingHoldbackSeconds == 16)
        #expect(h.edgeHoldbackSeconds == 26)
        // The cushion never asks for more than a join would hold.
        #expect(SoftwareLiveHoldback(deliveryUnitSeconds: 44).resumeCushionSeconds == 45)
    }

    @Test("the delivery unit is the larger of the served segment and the closed arrival gap")
    func deliveryUnitIsTheLarger() {
        #expect(SoftwareLiveHoldback.deliveryUnit(segmentDuration: 10.01, closedCadence: 9.98) == 10.01)
        #expect(SoftwareLiveHoldback.deliveryUnit(segmentDuration: 6, closedCadence: 12) == 12)
        #expect(SoftwareLiveHoldback.deliveryUnit(segmentDuration: 6, closedCadence: nil) == 6)
        #expect(SoftwareLiveHoldback.deliveryUnit(segmentDuration: nil, closedCadence: nil) == nil)
    }

    /// The reported shape: segments of `unit` landing once per `unit`, up to a second late. The
    /// lowest the lead gets is the join lead minus one unit minus the lateness, and it has to stay
    /// above the point where the clock parks.
    @Test("the join lead outlasts a late segment", arguments: [2.0, 4.0, 6.0, 10.0])
    func joinLeadOutlastsALateSegment(unit: Double) {
        let lateness = 1.0
        let lowest = SoftwareLiveHoldback(deliveryUnitSeconds: unit).joinLeadSeconds - unit - lateness
        #expect(lowest > AudioLookaheadPolicy.underrunPauseLeadSeconds)
    }

    // MARK: - The join

    @Test("the join is placed the segmented lead behind the newest media")
    func joinPlacesTheSegmentedLead() {
        var policy = SoftwareLiveJoinPolicy()
        let lead = SoftwareLiveHoldback(deliveryUnitSeconds: 10).joinLeadSeconds
        // The ingest's three-segment join has landed and nothing more arrives.
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now = 0.0
        while decision == nil, now < 5 {
            decision = policy.observe(firstPts: 18_028, newestPts: 18_058, at: now, leadSeconds: lead)
            now += 0.05
        }
        #expect(decision == .place(targetPts: 18_058 - 16))
    }

    @Test("a join holding less than the segmented lead plays from its start")
    func shortJoinPlaysFromStart() {
        var policy = SoftwareLiveJoinPolicy()
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now = 0.0
        while decision == nil, now < 5 {
            decision = policy.observe(firstPts: 0, newestPts: 12, at: now, leadSeconds: 16)
            now += 0.05
        }
        #expect(decision == .fromStart)
    }

    // MARK: - The rebuffer

    @Test("a rebuffer waits for the cushion even once the audio lead is back")
    func rebufferWaitsForTheCushion() {
        let held = AudioLookaheadPolicy.clockAction(
            rebuffering: true, lastFedAudioPTS: 12_004, clockSeconds: 12_000,
            atRingEnd: false, sourceEnded: false,
            bufferedAheadSeconds: 9.9, resumeCushionSeconds: 12)
        #expect(held == .none)
        let resumed = AudioLookaheadPolicy.clockAction(
            rebuffering: true, lastFedAudioPTS: 12_004, clockSeconds: 12_000,
            atRingEnd: false, sourceEnded: false,
            bufferedAheadSeconds: 12, resumeCushionSeconds: 12)
        #expect(resumed == .resume)
    }

    @Test("the cushion never holds a rebuffer the audio lead has not released")
    func cushionIsOnTopOfTheAudioLead() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: true, lastFedAudioPTS: 12_001, clockSeconds: 12_000,
            atRingEnd: false, sourceEnded: false,
            bufferedAheadSeconds: 30, resumeCushionSeconds: 12)
        #expect(a == .none)
    }

    @Test("source end resumes whatever the cushion")
    func sourceEndIgnoresTheCushion() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: true, lastFedAudioPTS: 12_000.5, clockSeconds: 12_000,
            atRingEnd: true, sourceEnded: true,
            bufferedAheadSeconds: 0.5, resumeCushionSeconds: 12)
        #expect(a == .resume)
    }

    // MARK: - Return to Live

    @Test("Return to Live lands the segmented holdback behind the frontier")
    func landingUsesTheHoldback() {
        var w = LiveWindow(windowSeconds: 120)
        w.noteEdge(600)
        let holdback = SoftwareLiveHoldback(deliveryUnitSeconds: 10).landingHoldbackSeconds
        #expect(AetherEngine.softwareLiveLanding(requested: 600, window: w, holdbackSeconds: holdback) == 584)
        #expect(AetherEngine.softwareLiveLanding(requested: 560, window: w, holdbackSeconds: holdback) == 560)
    }

    // MARK: - The edge verdict

    /// Plays a session placed the join lead behind a frontier that steps by `unit`, the first step
    /// `firstStepTick` half-second ticks after the placement, and returns how many ticks of two
    /// minutes the verdict called live.
    private func ticksAtEdge(unit: Double, holdback: Double?, firstStepTick: Int) -> Int {
        var w = LiveWindow(windowSeconds: 120)
        w.noteEdgeHoldback(holdback)
        let lead = SoftwareLiveHoldback(deliveryUnitSeconds: unit).joinLeadSeconds
        var edge = 1_000.0
        w.noteEdge(edge)
        var playhead = edge - lead
        var atEdge = 0
        let period = Int(unit * 2)
        for tick in 1...240 {   // 120 s of playback at half-second ticks
            playhead += 0.5
            if tick >= firstStepTick, (tick - firstStepTick) % period == 0 {
                edge += unit
                w.noteEdge(edge)
            }
            w.notePlayhead(playhead)
            w.settleEdgeVerdict(tracking: true)
            if w.isAtEdge { atEdge += 1 }
        }
        return atEdge
    }

    /// The placement measures from the newest media, so the next segment can land a tick after it
    /// (the distance then rides from `lead` up to `lead + unit`) or a whole unit later (from
    /// `lead - unit` up to `lead`). Measured on the harness: 25.5 s after a landing at 17 s.
    @Test("a session held the segmented lead behind stays at the edge in every phase",
          arguments: [1, 10, 20])
    func verdictHoldsWithTheHoldback(firstStepTick: Int) {
        let holdback = SoftwareLiveHoldback(deliveryUnitSeconds: 10).edgeHoldbackSeconds
        #expect(ticksAtEdge(unit: 10, holdback: holdback, firstStepTick: firstStepTick) == 240)
    }

    @Test("a holdback of the lead alone loses the edge when a segment lands right after placement")
    func leadAloneIsNotEnough() {
        let lead = SoftwareLiveHoldback(deliveryUnitSeconds: 10).joinLeadSeconds
        #expect(ticksAtEdge(unit: 10, holdback: lead, firstStepTick: 1) < 240)
    }

    @Test("without the holdback the same session is not called live")
    func verdictFailsWithoutTheHoldback() {
        #expect(ticksAtEdge(unit: 10, holdback: nil, firstStepTick: 20) < 240)
    }

    @Test("tracked distances do not widen a known holdback")
    func trackingDoesNotRatchetTheHoldback() {
        var w = LiveWindow(windowSeconds: 600)
        w.noteEdgeHoldback(26)
        w.noteEdge(1_000)
        // At the edge first, then sampled at the deep end of the exit slack, over and over.
        w.notePlayhead(1_000 - 20)
        w.settleEdgeVerdict(tracking: true)
        #expect(w.isAtEdge)
        for _ in 0..<24 {
            w.notePlayhead(1_000 - 29.5)
            w.settleEdgeVerdict(tracking: true)
        }
        #expect(w.edgeToleranceSeconds == LiveWindow.edgeTolerance + 26)
        // A deliberate rewind 20 s behind a session holding 16 s is not live.
        var fresh = LiveWindow(windowSeconds: 600)
        fresh.noteEdgeHoldback(26)
        fresh.noteEdge(1_000)
        fresh.notePlayhead(1_000 - 36)
        fresh.settleEdgeVerdict(tracking: true)
        #expect(!fresh.isAtEdge)
    }

    @Test("no holdback keeps the tolerance it had")
    func noHoldbackKeepsTheTolerance() {
        var w = LiveWindow(windowSeconds: 120)
        w.noteTargetDuration(6)
        let before = w.edgeToleranceSeconds
        w.noteEdgeHoldback(nil)
        #expect(w.edgeToleranceSeconds == before)
        w.noteEdgeHoldback(26)
        #expect(w.edgeToleranceSeconds == LiveWindow.edgeTolerance + 26)
    }
}
