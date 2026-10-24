import AVFoundation
import Testing
@testable import AetherEngine

@Suite("Audio AVPlayer host rebuffer fold")
struct AudioAVPlayerHostRebufferingTests {

    @Test("A wait before the item has ever played is startup, not a rebuffer")
    func startupWaitIsNotRebuffering() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: false, status: .waitingToPlayAtSpecifiedRate, waitingReason: .toMinimizeStalls, stalledSinceLastPlaying: false
        ) == false)
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: false, status: .waitingToPlayAtSpecifiedRate, waitingReason: .toMinimizeStalls, stalledSinceLastPlaying: true
        ) == false)
    }

    @Test("A wait after the item has played is a rebuffer")
    func waitAfterPlayingIsRebuffering() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .waitingToPlayAtSpecifiedRate, waitingReason: .toMinimizeStalls, stalledSinceLastPlaying: false
        ) == true)
    }

    @Test("Playing clears it; a stall latched since the last play holds it until then")
    func stallLatchCoversNotificationOrder() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .playing, waitingReason: nil, stalledSinceLastPlaying: false
        ) == false)
        // The stall notification can precede the status flip; the latch alone reports the rebuffer.
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .playing, waitingReason: nil, stalledSinceLastPlaying: true
        ) == true)
    }

    @Test("A paused player is never rebuffering, whatever it latched")
    func pausedIsNeverRebuffering() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .paused, waitingReason: nil, stalledSinceLastPlaying: true
        ) == false)
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .paused, waitingReason: nil, stalledSinceLastPlaying: false
        ) == false)
    }

    @Test("A resume's buffering-rate evaluation is not a rebuffer, a stall behind it is (Sodalite#168)")
    func resumeEvaluationIsNotRebuffering() {
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .waitingToPlayAtSpecifiedRate,
            waitingReason: .evaluatingBufferingRate, stalledSinceLastPlaying: false
        ) == false)
        #expect(AudioAVPlayerHost.rebufferingFlag(
            hasStartedPlaying: true, status: .waitingToPlayAtSpecifiedRate,
            waitingReason: .evaluatingBufferingRate, stalledSinceLastPlaying: true
        ) == true)
    }
}
