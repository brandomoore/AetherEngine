import Testing
import Foundation
@testable import AetherEngine

// The OCR worker, and the 270 s prefetch lead that comes with it, follow the NATIVE selection
// (PiP / AirPlay / external display), not the overlay selection. Measured on a 4K remux before this:
// 434 MB of prefetch in 90 s with the OCR armed at selection, 17 MB without.
@Suite("Subtitle OCR armed on native selection only", .serialized)
struct SubtitleOCRLazyArmingTests {

    @MainActor
    private func engineWithBitmapTrack() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: 3, language: "ger"),
            .init(sourceStreamIndex: 4, language: "ger", isForced: true, needsOCR: true),
        ]
        engine.testHookInstallNativeStores([NativeSubtitleCueStore(), NativeSubtitleCueStore()])
        engine.activeEmbeddedSubtitleStreamIndex = 4
        return engine
    }

    @MainActor
    @Test("selecting the bitmap rendition arms the worker, deselecting disarms it")
    func armsAndDisarmsWithNativeSelection() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        #expect(engine.subtitleOCRArmedOrdinal == nil)
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        #expect(engine.subtitleOCRArmedOrdinal == 1)
        engine.syncSubtitleOCRWithNativeSelection(ordinal: nil)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @MainActor
    @Test("a text rendition never arms the worker and disarms a bitmap one")
    func textRenditionDisarms() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 0)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @MainActor
    @Test("a bitmap rendition that is not the active overlay track does not arm")
    func otherBitmapTrackDoesNotArm() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        engine.activeEmbeddedSubtitleStreamIndex = 7
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @MainActor
    @Test("re-selecting the armed ordinal keeps the running worker")
    func reselectKeepsWorker() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        let task = engine.subtitleOCRWorkerTask
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        #expect(engine.subtitleOCRWorkerTask != nil)
        #expect(engine.subtitleOCRWorkerTask == task)
    }

    @Test("the window counts as covered only when read and fully decoded")
    func coverageRule() {
        #expect(AetherEngine.subtitleOCRWindowCovered(harvestRead: true, undecodedPackets: 0))
        #expect(!AetherEngine.subtitleOCRWindowCovered(harvestRead: false, undecodedPackets: 0))
        #expect(!AetherEngine.subtitleOCRWindowCovered(harvestRead: true, undecodedPackets: 2))
    }
}
