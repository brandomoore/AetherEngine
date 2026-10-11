import Foundation
import Testing
@testable import AetherEngine

@Suite("Live loopback timestamp rollback")
struct LiveTimestampRollbackTests {
    @MainActor
    @Test("a source PTS rollback cannot move the DVR rail or seek beyond the item edge")
    func rollbackKeepsSessionAxis() throws {
        let engine = try AetherEngine()
        engine.isLive = true
        engine.videoRoute = .loopback
        engine.liveDisplayShiftSeconds = 67_310.539
        engine.playlistShiftSeconds = 67_310.539
        engine.nativeSeekableEndReading = { 40.24 }
        engine.liveWindow = LiveWindow(windowSeconds: 1_800)

        engine.setPresentationAxis(.anchored(shiftSeconds: 67_310.539))
        engine.applyNativeHostClockTick(26.0)
        let before = engine.currentTime

        var sourceAxis = engine.presentationAxis
        sourceAxis.appendSeam(shiftSeconds: 67_293.099, activatingAtItemSeconds: 27.44)
        engine.setPresentationAxis(sourceAxis)
        engine.applyNativeHostClockTick(35.0)

        #expect(abs(engine.currentTime - (before + 9)) < 0.001)
        #expect(abs(engine.liveWindow!.edgeTime - 67_350.779) < 0.001)
        #expect(abs(engine.displaySeconds(forPlaylistSeconds: 35) - 67_345.539) < 0.001)
        #expect(abs(engine.liveSessionSeekAxis.itemSeconds(forSourceSeconds: engine.currentTime)! - 35) < 0.001)

        let landing = AetherEngine.liveSeekLanding(
            requested: engine.liveWindow!.edgeTime,
            window: engine.liveWindow!, itemEnd: 40.24,
            shift: engine.liveSessionShiftSeconds,
            axis: engine.liveSessionSeekAxis)
        // The source seam would invert this same edge to 57.68, beyond the item's 40.24 end.
        #expect(abs(sourceAxis.itemSeconds(forSourceSeconds: engine.liveWindow!.edgeTime)! - 57.68) < 0.001)
        #expect(abs(landing.clockTarget - 40.24) < 0.001)
        #expect(landing.clockTarget <= 40.24)
    }
    @Test("A stale range admits played resident media but never a prefetched frontier")
    func staleRangeUsesPlayedHistory() {
        #expect(AetherEngine.nativePlayedResidentEdge(reportedEdge: 0, playedTime: 24,
            publishedEdge: 20, residentRange: 10...100) == 24)
        #expect(AetherEngine.nativePlayedResidentEdge(reportedEdge: 0, playedTime: 14,
            publishedEdge: 24, residentRange: 10...100) == 24)
        #expect(AetherEngine.nativePlayedResidentEdge(reportedEdge: 0, playedTime: 4,
            publishedEdge: 4, residentRange: 10...100) == 10)
        #expect(AetherEngine.nativePlayedResidentEdge(reportedEdge: 40, playedTime: 24,
            publishedEdge: 20, residentRange: 10...100) == nil)
        #expect(AetherEngine.nativePlayedResidentEdge(reportedEdge: 0, playedTime: .nan,
            publishedEdge: 20, residentRange: 10...100) == nil)
    }
}
