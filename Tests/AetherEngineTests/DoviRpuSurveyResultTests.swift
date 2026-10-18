import Testing
import Foundation
@_spi(Diagnostics) @testable import AetherEngine

/// The pure half of `aetherctl dvsurvey`: what `DoviRpuSurveyResult` makes of a list of frames, and
/// the PQ-to-nits conversion it reports with. The RPU parsing itself needs libdovi and a real
/// bitstream and is covered by the real-clip suites.
@Suite("Dolby Vision RPU survey aggregation")
struct DoviRpuSurveyResultTests {

    private func frame(_ index: Int, min: UInt16, avg: UInt16, max: UInt16) -> DoviRpuFrameSurvey {
        DoviRpuFrameSurvey(frameIndex: index, sceneRefresh: false,
                           l1MinPQ: min, l1AvgPQ: avg, l1MaxPQ: max,
                           l2Trims: [], sourceMinPQ: 0, sourceMaxPQ: 4095, payloadBytes: 100)
    }

    private func result(_ frames: [DoviRpuFrameSurvey]) -> DoviRpuSurveyResult {
        DoviRpuSurveyResult(frames: frames, packetsProcessed: frames.count, rpuFailures: 0,
                            enhancementLayerType: nil)
    }

    @Test("an empty survey picks nothing")
    func emptySurvey() {
        let r = result([])
        #expect(r.darkestFrame == nil)
        #expect(r.brightestFrame == nil)
        #expect(r.strongestPoison == nil)
        #expect(r.medianL1 == nil)
    }

    @Test("darkest and brightest rank on avg_pq, not max_pq")
    func darkestAndBrightestRankOnAverage() throws {
        // Frame 1 has the highest max_pq and the lowest avg_pq: a bright highlight in a near-black frame.
        let r = result([frame(0, min: 0, avg: 1500, max: 2500),
                        frame(1, min: 0, avg: 300, max: 4000),
                        frame(2, min: 0, avg: 2200, max: 2600)])
        #expect(try #require(r.darkestFrame).frameIndex == 1)
        #expect(try #require(r.brightestFrame).frameIndex == 2)
    }

    @Test("the median is taken per field")
    func medianPerField() throws {
        let r = result([frame(0, min: 10, avg: 900, max: 3000),
                        frame(1, min: 30, avg: 100, max: 2000),
                        frame(2, min: 20, avg: 500, max: 4000)])
        let m = try #require(r.medianL1)
        #expect(m.min == 20)
        #expect(m.avg == 500)
        #expect(m.max == 3000)
    }

    @Test("the strongest pin is the frame furthest from the median across all three fields")
    func strongestPoisonScoresAllFields() throws {
        // Median is (min 0, avg 1000, max 2000). Frame 3 sits 100 off on avg and 1900 off on max;
        // frame 4 sits 1500 off on avg alone, so the total (2000 against 1500) decides.
        let r = result([frame(0, min: 0, avg: 1000, max: 2000),
                        frame(1, min: 0, avg: 1000, max: 2000),
                        frame(2, min: 0, avg: 1000, max: 2000),
                        frame(3, min: 0, avg: 1100, max: 3900),
                        frame(4, min: 0, avg: 2500, max: 2000)])
        let p = try #require(r.strongestPoison)
        #expect(p.frame.frameIndex == 3)
        #expect(p.deltaPQ == 2000)
        #expect(p.dominantField == "max_pq")
    }

    @Test("the dominant field breaks ties toward avg_pq, then max_pq")
    func dominantFieldTieBreak() throws {
        let flat = (0..<5).map { frame($0, min: 100, avg: 1000, max: 2000) }
        func dominant(of outlier: DoviRpuFrameSurvey) throws -> String {
            try #require(result(flat + [outlier]).strongestPoison).dominantField
        }
        #expect(try dominant(of: frame(9, min: 100, avg: 1500, max: 2500)) == "avg_pq")
        #expect(try dominant(of: frame(9, min: 100, avg: 1000, max: 2500)) == "max_pq")
        #expect(try dominant(of: frame(9, min: 600, avg: 1000, max: 2000)) == "min_pq")
    }

    @Test("a flat title scores zero distance")
    func flatTitleHasNoDistance() throws {
        let r = result((0..<8).map { frame($0, min: 0, avg: 1000, max: 2000) })
        #expect(try #require(r.strongestPoison).deltaPQ == 0)
    }

    @Test("PQ codes convert to nits at the anchors and clamp outside the range")
    func pqCodeToNits() {
        #expect(DoviRpuSurvey.pqCodeToNits(0) == 0)
        #expect(abs(DoviRpuSurvey.pqCodeToNits(4095) - 10000) < 1)
        // PQ 0.508 is 100 nits; code 2081 of 4095 is 0.5081.
        #expect(abs(DoviRpuSurvey.pqCodeToNits(2081) - 100) < 2)
        // The curve is monotonic.
        var previous = -1.0
        for code in stride(from: 0, through: 4095, by: 64) {
            let nits = DoviRpuSurvey.pqCodeToNits(UInt16(code))
            #expect(nits > previous)
            previous = nits
        }
        // Codes above 12 bits clamp to the peak instead of producing NaN.
        #expect(abs(DoviRpuSurvey.pqCodeToNits(UInt16.max) - 10000) < 1)
    }
}
