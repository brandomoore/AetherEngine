import Testing
@testable import AetherEngine

@Suite("Display-criteria action on the load() seam")
struct DisplayCriteriaLoadActionTests {

    @Test("Video load with the engine as criteria writer applies fresh criteria in place")
    func videoEngineWriterAppliesFresh() {
        #expect(AetherEngine.loadDisplayCriteriaAction(engineWritesCriteria: true, audioOnlyPath: false) == .applyFresh)
    }

    @Test("Suppressed (AVKit-sole-writer) load clears a stale engine criteria instead of applying")
    func suppressedClearsStale() {
        // A previous non-suppressed session may have left its criteria applied across the preserved
        // load seam; leaving it in place alongside AVKit's own write recreates the dual-writer fight.
        #expect(AetherEngine.loadDisplayCriteriaAction(engineWritesCriteria: false, audioOnlyPath: false) == .clearStale)
    }

    @Test("Audio-only load clears a stale criteria so music cannot inherit the video session's panel mode")
    func audioOnlyClearsStale() {
        #expect(AetherEngine.loadDisplayCriteriaAction(engineWritesCriteria: true, audioOnlyPath: true) == .clearStale)
    }

    @Test("Suppressed audio-only load also clears")
    func suppressedAudioOnlyClearsStale() {
        #expect(AetherEngine.loadDisplayCriteriaAction(engineWritesCriteria: false, audioOnlyPath: true) == .clearStale)
    }
}
