import XCTest
@testable import AetherEngine

@MainActor
final class AudioSelectionOwnershipTests: XCTestCase {
    private func fixture() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://example.invalid/controlled.ts")!
        engine.audioTracks = [1, 2].map {
            TrackInfo(id: $0, name: "Track \($0)", codec: "aac", language: nil, isDefault: $0 == 1)
        }
        engine.activeAudioTrackIndex = 1
        return engine
    }

    func testSameAudioDoesNotScheduleRebuild() throws {
        let engine = try fixture()
        defer { engine.stop() }
        engine.selectAudioTrack(index: 1)
        XCTAssertNil(engine.audioSelectionTask)
    }

    func testRapidSelectionReturningToCurrentAudioCoalescesBeforeIO() async throws {
        let engine = try fixture()
        defer { engine.stop() }
        let generation = engine.loadGeneration
        engine.selectAudioTrack(index: 2)
        engine.selectAudioTrack(index: 1)
        await engine.audioSelectionTask?.value
        XCTAssertEqual(engine.loadGeneration, generation)
        XCTAssertEqual(engine.activeAudioTrackIndex, 1)
        XCTAssertNil(engine.audioSelectionTask)
    }

    func testStopInvalidatesQueuedAudioWorkBeforeItCanReopenSource() async throws {
        let engine = try fixture()
        engine.selectAudioTrack(index: 2)
        let task = try XCTUnwrap(engine.audioSelectionTask)
        engine.stop()
        let stoppedGeneration = engine.loadGeneration
        await task.value
        XCTAssertEqual(engine.loadGeneration, stoppedGeneration)
        XCTAssertNil(engine.loadedURL)
        XCTAssertEqual(engine.state, .idle)
    }

    func testLiveURLDoesNotRequireHostReload() throws {
        let engine = try fixture()
        defer { engine.stop() }
        engine.isLive = true
        XCTAssertNil(engine.sessionReloadRefusal)
    }
}
