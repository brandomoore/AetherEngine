import Foundation
import Testing
@testable import AetherEngine

/// Audit NAT-103: an in-place item swap (AE#629) reuses a player that is still `.playing`, and that
/// status reaches the fresh item about 1 ms after the load, long before it is ready. The swap's clock
/// hold and #50's `hasEverPlayed` both took it for the item rolling: the hold let AVPlayer's
/// pre-landing readings through to the published clock (15.97 s, then 12.00 s, then up again on the
/// AE#629 harness), and a swapped item that failed at startup took the post-playback branch.
@Suite("An in-place swap waits for the fresh item's own roll")
struct InPlaceSwapRollTests {

    @Test("A playing status carried onto an item that is not ready is not its roll")
    func carriedPlayingIsNotARoll() {
        #expect(!NativeAVPlayerHost.playingIsThisItemsRoll(itemIsReadyToPlay: false))
        #expect(NativeAVPlayerHost.playingIsThisItemsRoll(itemIsReadyToPlay: true))
    }

    /// A host-level test cannot put AVFoundation's carried edge on a fresh item, so this one reads the
    /// sink, as the #98 placement test does.
    @Test("The status sink releases the hold and latches has-played only on the item's roll")
    func statusSinkGatesOnTheRoll() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/Native/NativeAVPlayerHost.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let sink = try #require(text.range(of: "timeControlObservation = avPlayer.observe(\\.timeControlStatus"))
        let body = String(text[sink.upperBound...].prefix(3000))
        let gate = try #require(body.range(of: "Self.playingIsThisItemsRoll(itemIsReadyToPlay:"))
        let latch = try #require(body.range(of: "self.hasEverPlayed = true"))
        let release = try #require(body.range(of: "self.mountSeekPending = false"))
        #expect(gate.lowerBound < latch.lowerBound)
        #expect(gate.lowerBound < release.lowerBound)
    }
}
