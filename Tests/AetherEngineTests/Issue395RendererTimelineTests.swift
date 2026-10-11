import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// AE#395: a software session hands its renderers stamps relative to a session origin, so an AirPlay
/// receiver that fails past 2^31 samples of 48 kHz never sees a broadcast clock. The source axis above
/// the renderers must not move.
@Suite("AE#395 renderer timeline")
struct Issue395RendererTimelineTests {

    @Test("a source that starts near zero keeps the stamps it always had")
    func ordinarySourceIsUntouched() {
        #expect(RendererTimelinePolicy.origin(firstSourceSeconds: 0) == 0)
        #expect(RendererTimelinePolicy.origin(firstSourceSeconds: 599) == 0)
        #expect(RendererTimelinePolicy.origin(firstSourceSeconds: RendererTimelinePolicy.headroomSeconds) == 0)
        #expect(RendererTimelinePolicy.origin(firstSourceSeconds: .nan) == 0)
        #expect(RendererTimelinePolicy.origin(firstSourceSeconds: -5) == 0)
    }

    @Test("every clock Jos measured on the Belkin starts its renderers well below the 44739 s line")
    func measuredClocksLandBelowTheLine() {
        let line = Double(Int32.max) / 48000
        for first in [40001.970, 50001.970, 59670.451, 59671.841, 95000.0] {
            let origin = RendererTimelinePolicy.origin(firstSourceSeconds: first)
            let start = first - origin
            #expect(start >= RendererTimelinePolicy.headroomSeconds)
            #expect(start < RendererTimelinePolicy.headroomSeconds + 1)
            #expect(start < line)
        }
    }

    @Test("the origin latches once and both directions are inverses")
    func latchesOnceAndRoundTrips() {
        let timeline = RendererTimeline()
        #expect(timeline.origin == nil)
        let first = timeline.rendererTime(forSource: CMTime(seconds: 59670.451, preferredTimescale: 90000))
        #expect(timeline.origin == 48870)
        #expect(abs(first.seconds - 10800.451) < 0.001)

        // A later, earlier and much later stamp all use the same origin.
        for source in [59671.0, 59000.0, 70000.0] {
            let renderer = timeline.rendererTime(forSource: CMTime(seconds: source, preferredTimescale: 90000))
            #expect(abs(renderer.seconds - (source - 48870)) < 0.001)
            #expect(abs(timeline.sourceTime(forRenderer: renderer).seconds - source) < 0.001)
        }
        #expect(timeline.origin == 48870)
    }

    @Test("a read before the first stamp neither latches nor shifts")
    func readBeforeLatchIsIdentity() {
        let timeline = RendererTimeline()
        let t = CMTime(seconds: 12, preferredTimescale: 90000)
        #expect(timeline.sourceTime(forRenderer: t) == t)
        #expect(timeline.origin == nil)
        #expect(timeline.rendererTime(forSource: .invalid) == .invalid)
        #expect(timeline.origin == nil)
    }

    @Test("the clock anchor reads back on the source axis while the synchronizer runs near the origin")
    func audioOutputClockRoundTrips() {
        let output = AudioOutput()
        output.seekClock(to: CMTime(seconds: 59670.451, preferredTimescale: 90000), rate: 0)
        #expect(abs(output.currentTimeSeconds - 59670.451) < 0.01)
        #expect(abs(output.synchronizer.currentTime().seconds - 10800.451) < 0.01)
        let timebaseSeconds = CMTimebaseGetTime(output.sourceTimebase).seconds
        #expect(abs(timebaseSeconds - 59670.451) < 0.01)
        output.stop()
    }

    @Test("an ordinary session's synchronizer still runs on the source PTS")
    func audioOutputOrdinarySessionUnchanged() {
        let output = AudioOutput()
        output.seekClock(to: CMTime(seconds: 12.5, preferredTimescale: 90000), rate: 0)
        #expect(abs(output.synchronizer.currentTime().seconds - 12.5) < 0.01)
        #expect(output.sourceTimebase === output.synchronizer.timebase)
        output.stop()
    }
}
