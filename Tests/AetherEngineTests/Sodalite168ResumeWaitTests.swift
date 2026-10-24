import AVFoundation
import Testing
@testable import AetherEngine

/// Sodalite#168: a resume from pause passes through `waitingToPlay` with `evaluatingBufferingRate` for a
/// frame or two. Published as a rebuffer, it flashed a host's spinner and took its chrome down with it.
@Suite("Sodalite#168 native wait: evaluation is not a rebuffer")
struct Sodalite168ResumeWaitTests {

    @Test("A wait evaluating the buffering rate is not a rebuffer")
    func evaluationIsNotRebuffer() {
        #expect(!AetherEngine.nativeWaitIsRebuffer(status: .waitingToPlayAtSpecifiedRate,
                                                   reason: .evaluatingBufferingRate))
    }

    @Test("A wait short of media, or with any other or missing reason, still is")
    func otherWaitsAreRebuffers() {
        #expect(AetherEngine.nativeWaitIsRebuffer(status: .waitingToPlayAtSpecifiedRate,
                                                  reason: .toMinimizeStalls))
        #expect(AetherEngine.nativeWaitIsRebuffer(status: .waitingToPlayAtSpecifiedRate,
                                                  reason: .noItemToPlay))
        #expect(AetherEngine.nativeWaitIsRebuffer(status: .waitingToPlayAtSpecifiedRate, reason: nil))
    }

    @Test("Playing or paused is never a rebuffer, whatever reason is left over")
    func noWaitNoRebuffer() {
        #expect(!AetherEngine.nativeWaitIsRebuffer(status: .playing, reason: .toMinimizeStalls))
        #expect(!AetherEngine.nativeWaitIsRebuffer(status: .paused, reason: .toMinimizeStalls))
    }
}
