import Testing
import Foundation
@testable import AetherEngine

/// `HEVCPictureOrderCount` against hand-built parameter sets and slice headers: every expected POC
/// below is worked out from H.265 §8.3.1 by hand, not by running the reader. (The real-clip tests
/// in `DualLayerPictureAlignmentTests` need files that are not in the repository.)
struct HEVCPictureOrderCountTests {

    typealias B = HEVCSyntheticBitstream
    typealias T = HEVCSyntheticBitstream.T

    /// A counter with SPS 0 / PPS 0 loaded, 4-bit POC LSB (MaxPicOrderCntLsb = 16) unless told otherwise.
    private static func counter(pocLsbBits: Int = 4, pps: [UInt8]? = nil, sps: [UInt8]? = nil) -> HEVCPictureOrderCount {
        var c = HEVCPictureOrderCount()
        c.feedParameterSets([sps ?? B.sps(pocLsbBits: pocLsbBits), pps ?? B.pps()])
        return c
    }

    private static func feed(_ c: inout HEVCPictureOrderCount, _ nal: [UInt8]) -> HEVCPictureOrderCount.Picture? {
        nal.withUnsafeBufferPointer { c.feed($0.baseAddress!, $0.count) }
    }

    private static func slice(_ type: Int, lsb: Int = 0, tid: Int = 0, bits: Int = 4) -> [UInt8] {
        B.slice(type: type, temporalId: tid, pocLsb: lsb, pocLsbBits: bits)
    }

    // MARK: - MSB wrap

    @Test("POC MSB wraps forward: LSB falling by half the range or more adds MaxPicOrderCntLsb")
    func msbWrapsForward() {
        var c = Self.counter()
        #expect(Self.feed(&c, Self.slice(T.idrNLP)) == .init(poc: 0, startsSequence: true))
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 5))?.poc == 5)
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 10))?.poc == 10)
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 15))?.poc == 15)
        // prevLsb 15, lsb 4: 15 - 4 = 11 >= 8, so MSB += 16 -> 16 + 4
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 4))?.poc == 20)
        // And a second wrap
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 9))?.poc == 25)
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 14))?.poc == 30)
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 3))?.poc == 35)
    }

    @Test("POC MSB wraps backward: LSB rising by more than half the range subtracts MaxPicOrderCntLsb")
    func msbWrapsBackward() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 6))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 12))
        // prevTid0 = 12 (lsb 12, msb 0); lsb 4 -> 12 - 4 = 8 >= 8: wraps forward to 20
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 4))?.poc == 20)
        // prevTid0 = 20 (lsb 4, msb 16); lsb 15: 15 - 4 = 11 > 8 -> MSB = 16 - 16 = 0 -> 15 (a picture
        // displayed before the one at 20, as a B-frame under a wrap would be)
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 15))?.poc == 15)
    }

    @Test("a half-range step is a wrap one way and not the other (the spec's strict and non-strict comparisons)")
    func halfRangeBoundary() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 8))
        // lsb 0, prev 8: prev - lsb = 8 >= 8, wraps forward -> 16
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 0))?.poc == 16)
        // lsb 8, prev 0 (of 16): lsb - prev = 8, not > 8, so no wrap -> 24
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 8))?.poc == 24)
    }

    // MARK: - Sequence starts

    @Test("IDR and BLA start a sequence at MSB 0; BLA keeps its LSB")
    func idrAndBlaStartSequences() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrWRADL))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 7))
        let bla = Self.feed(&c, Self.slice(T.blaWLP, lsb: 9))
        #expect(bla == .init(poc: 9, startsSequence: true))
        // POC numbering restarts: the next picture is relative to the BLA, not to the IDR's sequence
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 10))?.poc == 10)
    }

    @Test("a CRA in the middle of a sequence continues the numbering; after reset() it starts one (CRA handled as BLA)")
    func craAsBlaAfterReset() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 7))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 15))
        // Mid-sequence CRA: NoRaslOutputFlag = 0, POC continues across the wrap (16 + 3)
        #expect(Self.feed(&c, Self.slice(T.cra, lsb: 3)) == .init(poc: 19, startsSequence: false))

        c.reset()
        // Pictures before the first IRAP after a seek are not decodable: no POC
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 4)) == nil)
        // The CRA opens a sequence (HandleCraAsBlaFlag): MSB 0, so POC = LSB
        #expect(Self.feed(&c, Self.slice(T.cra, lsb: 3)) == .init(poc: 3, startsSequence: true))
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 5))?.poc == 5)
    }

    @Test("end of sequence and end of bitstream NALs make the next IRAP a sequence start and hide what precedes it")
    func endOfSequenceAndBitstream() {
        for eosType in [T.eos, T.eob] {
            var c = Self.counter()
            _ = Self.feed(&c, Self.slice(T.idrNLP))
            _ = Self.feed(&c, Self.slice(T.trailR, lsb: 5))
            #expect(Self.feed(&c, B.nal(type: eosType, rbsp: [0x80])) == nil)
            #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 6)) == nil, "no picture is decodable between the end of sequence and the next IRAP")
            // A CRA after the end of sequence has NoRaslOutputFlag = 1
            #expect(Self.feed(&c, Self.slice(T.cra, lsb: 11)) == .init(poc: 11, startsSequence: true))
            #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 12))?.poc == 12)
        }
    }

    // MARK: - prevTid0Pic

    /// prevTid0Pic is the previous TemporalId-0 picture that is not RASL, RADL or a sub-layer
    /// non-reference picture. Each excluded kind is fed with an LSB that would change the result
    /// if it had been taken as the reference.
    @Test("RASL, RADL, sub-layer non-reference pictures and TemporalId > 0 are not prevTid0Pic",
          arguments: [T.trailN, T.tsaN, T.radlN, T.radlR, T.raslN, T.raslR])
    func excludedFromPrevTid0(type: Int) {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 2))?.poc == 2)          // prevTid0 = 2
        // The excluded picture: POC 9 relative to prevTid0 = 2 (9 - 2 = 7, no wrap)
        #expect(Self.feed(&c, Self.slice(type, lsb: 9))?.poc == 9)
        // If it had become prevTid0 (9), lsb 14 would be poc 14. Relative to 2 it is 14 - 2 = 12 > 8,
        // a backward wrap: 14 - 16 = -2.
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 14))?.poc == -2)
    }

    @Test("a picture with TemporalId > 0 is not prevTid0Pic")
    func higherTemporalLayerExcluded() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 2))
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 9, tid: 1))?.poc == 9)
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 14))?.poc == -2)
    }

    @Test("a reference picture at TemporalId 0 is prevTid0Pic")
    func referencePictureIsPrevTid0() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 2))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 9))
        // prevTid0 = 9: lsb 14 is 14 - 9 = 5 ahead, no wrap
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 14))?.poc == 14)
    }

    // MARK: - Leading pictures after a sequence-opening CRA

    @Test("RASL pictures of a CRA that opens a sequence get no POC; RADL and trailing pictures do")
    func raslSkippedAfterOpeningCra() {
        for rasl in [T.raslN, T.raslR] {
            var c = Self.counter()
            c.reset()
            #expect(Self.feed(&c, Self.slice(T.cra, lsb: 8))?.startsSequence == true)
            #expect(Self.feed(&c, Self.slice(rasl, lsb: 6)) == nil, "RASL of a CRA with NoRaslOutputFlag = 1 is not output")
            #expect(Self.feed(&c, Self.slice(T.radlR, lsb: 7))?.poc == 7, "RADL is decodable and output before the CRA")
            #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 9))?.poc == 9)
        }
    }

    @Test("RASL pictures of a CRA in the middle of a sequence are ordinary pictures")
    func raslKeptAfterMidStreamCra() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        _ = Self.feed(&c, Self.slice(T.trailR, lsb: 4))
        #expect(Self.feed(&c, Self.slice(T.cra, lsb: 8))?.startsSequence == false)
        #expect(Self.feed(&c, Self.slice(T.raslR, lsb: 6))?.poc == 6)
    }

    @Test("an IDR clears the RASL skip a previous CRA set")
    func idrClearsRaslSkip() {
        var c = Self.counter()
        c.reset()
        _ = Self.feed(&c, Self.slice(T.cra, lsb: 8))
        _ = Self.feed(&c, Self.slice(T.idrWRADL))
        // Not a legal stream (an IDR has no RASL), but the skip must not outlive its IRAP
        #expect(Self.feed(&c, Self.slice(T.raslN, lsb: 1))?.poc == 1)
    }

    @Test("the RASL skip ends at the next IRAP; BLA also opens it")
    func blaSkipsRasl() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        _ = Self.feed(&c, Self.slice(T.blaWLP, lsb: 8))
        #expect(Self.feed(&c, Self.slice(T.raslN, lsb: 6)) == nil)
        _ = Self.feed(&c, Self.slice(T.cra, lsb: 12))      // mid-sequence CRA: RASL are output again
        #expect(Self.feed(&c, Self.slice(T.raslN, lsb: 10))?.poc == 10)
    }

    // MARK: - Header syntax

    @Test("emulation prevention bytes inside the parameter sets and the slice header are removed before parsing")
    func emulationPrevention() {
        // The SPS carries 6 zero bytes of constraint flags, which always needs escaping
        let sps = B.sps(pocLsbBits: 16)
        #expect(sps.contains(0x03))
        #expect(Array(sps).windows3.contains { $0 == [0, 0, 3] })
        // Slice: first_slice 1, no_output 0, pps ue(0) = 1, two extra bits 00, slice_type ue(2) = 011
        // makes byte 0 = 10100011; a 16-bit POC LSB of 0 then gives two zero bytes, and the following
        // 00000001 byte makes the sequence 00 00 01, which must be escaped to 00 00 03 01.
        let pps = B.pps(extraSliceHeaderBits: 2)
        let cra = B.slice(type: T.cra, extraBits: 2, pocLsb: 0, pocLsbBits: 16, afterPOC: (1, 8))
        #expect(cra.windows3.contains { $0 == [0, 0, 3] }, "the slice must actually contain an escape")
        var c = HEVCPictureOrderCount()
        c.feedParameterSets([sps, pps])
        c.reset()
        #expect(Self.feed(&c, cra) == .init(poc: 0, startsSequence: true))
        let trail = B.slice(type: T.trailR, extraBits: 2, pocLsb: 0x0003, pocLsbBits: 16)
        #expect(Self.feed(&c, trail)?.poc == 3)
    }

    @Test("num_extra_slice_header_bits shifts where slice_type and the POC LSB sit")
    func extraSliceHeaderBits() {
        for extra in [0, 1, 3, 7] {
            var c = HEVCPictureOrderCount()
            c.feedParameterSets([B.sps(pocLsbBits: 6), B.pps(extraSliceHeaderBits: extra)])
            _ = Self.feed(&c, B.slice(type: T.idrNLP, extraBits: extra, extraBitsValue: (1 << extra) - 1, pocLsbBits: 6))
            let p = Self.feed(&c, B.slice(type: T.trailR, extraBits: extra, extraBitsValue: (1 << extra) - 1,
                                          pocLsb: 20, pocLsbBits: 6))
            #expect(p?.poc == 20, "extra bits = \(extra)")
        }
    }

    @Test("pic_output_flag is read when output_flag_present_flag is set, and only then")
    func outputFlagPresent() {
        var with = HEVCPictureOrderCount()
        with.feedParameterSets([B.sps(pocLsbBits: 8), B.pps(outputFlagPresent: true)])
        _ = Self.feed(&with, B.slice(type: T.idrNLP, outputFlag: true, pocLsbBits: 8))
        // A picture with pic_output_flag = 0 still has a POC, and still moves prevTid0Pic
        #expect(Self.feed(&with, B.slice(type: T.trailR, outputFlag: false, pocLsb: 77, pocLsbBits: 8))?.poc == 77)
        #expect(Self.feed(&with, B.slice(type: T.trailR, outputFlag: true, pocLsb: 78, pocLsbBits: 8))?.poc == 78)

        // Without the flag in the PPS, a slice that does not carry it parses the same LSB
        var without = HEVCPictureOrderCount()
        without.feedParameterSets([B.sps(pocLsbBits: 8), B.pps(outputFlagPresent: false)])
        _ = Self.feed(&without, B.slice(type: T.idrNLP, pocLsbBits: 8))
        #expect(Self.feed(&without, B.slice(type: T.trailR, pocLsb: 77, pocLsbBits: 8))?.poc == 77)
    }

    @Test("colour_plane_id is read when separate_colour_plane_flag is set (4:4:4 coded as three planes)")
    func separateColourPlane() {
        var c = HEVCPictureOrderCount()
        c.feedParameterSets([B.sps(pocLsbBits: 8, chromaFormatIdc: 3, separateColourPlane: true), B.pps()])
        _ = Self.feed(&c, B.slice(type: T.idrNLP, colourPlane: 0, pocLsbBits: 8))
        #expect(Self.feed(&c, B.slice(type: T.trailR, colourPlane: 1, pocLsb: 41, pocLsbBits: 8))?.poc == 41)

        // 4:4:4 with the planes together has no colour_plane_id
        var joint = HEVCPictureOrderCount()
        joint.feedParameterSets([B.sps(pocLsbBits: 8, chromaFormatIdc: 3, separateColourPlane: false), B.pps()])
        _ = Self.feed(&joint, B.slice(type: T.idrNLP, pocLsbBits: 8))
        #expect(Self.feed(&joint, B.slice(type: T.trailR, pocLsb: 41, pocLsbBits: 8))?.poc == 41)
    }

    @Test("sub-layer profile/level flags in the SPS are skipped correctly")
    func spsWithSubLayers() {
        var c = HEVCPictureOrderCount()
        c.feedParameterSets([B.sps(pocLsbBits: 9, subLayers: 3), B.pps()])
        _ = Self.feed(&c, B.slice(type: T.idrNLP, pocLsbBits: 9))
        #expect(Self.feed(&c, B.slice(type: T.trailR, pocLsb: 200, pocLsbBits: 9))?.poc == 200)
    }

    // MARK: - Missing or unusable input

    @Test("a slice whose PPS or SPS has not been seen has no POC; it gets one once they arrive")
    func missingParameterSets() {
        var c = HEVCPictureOrderCount()
        let idr = B.slice(type: T.idrNLP, pocLsbBits: 8)
        #expect(Self.feed(&c, idr) == nil, "no PPS, no SPS")
        _ = Self.feed(&c, B.pps(id: 0, spsID: 0))
        #expect(Self.feed(&c, idr) == nil, "PPS refers to an SPS that has not been seen")
        _ = Self.feed(&c, B.sps(id: 0, pocLsbBits: 8))
        #expect(Self.feed(&c, B.slice(type: T.idrNLP, ppsID: 5, pocLsbBits: 8)) == nil, "PPS id 5 was never sent")
        #expect(Self.feed(&c, idr) == .init(poc: 0, startsSequence: true))
    }

    @Test("a picture that is not the first slice segment is ignored and does not disturb state")
    func nonFirstSliceIgnored() {
        var c = Self.counter()
        _ = Self.feed(&c, Self.slice(T.idrNLP))
        #expect(Self.feed(&c, B.slice(type: T.trailR, firstSliceSegment: false, pocLsb: 9, pocLsbBits: 4)) == nil)
        // prevTid0 is still 0: lsb 9 is 9 > 8 ahead, a backward wrap -> -7. Had the second slice
        // been taken as a picture (prevTid0 = 9) it would read 9 -> 9.
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 9))?.poc == -7)
    }

    @Test("pictures before the first IRAP, truncated headers and junk NALs answer nil")
    func rejectsWhatItCannotFollow() {
        var c = Self.counter()
        #expect(Self.feed(&c, Self.slice(T.trailR, lsb: 3)) == nil, "no IRAP yet")
        #expect(Self.feed(&c, Array(Self.slice(T.idrNLP).prefix(2))) == nil, "a bare NAL header")
        #expect(Self.feed(&c, [0x02]) == nil)
        #expect(Self.feed(&c, B.nal(type: 39, rbsp: [0x00, 0x01])) == nil, "an SEI is not a picture")
        #expect(Self.feed(&c, B.nal(type: 32, rbsp: [0x0C, 0x01])) == nil, "nor is a VPS")
        // The decoder still works afterwards
        #expect(Self.feed(&c, Self.slice(T.idrNLP))?.poc == 0)
        // A slice header cut off inside the POC LSB, after an IRAP so that the truncation is the only
        // reason to answer nil: the same header complete is a picture
        let trail = Self.slice(T.trailR, lsb: 5)
        #expect(Self.feed(&c, Array(trail.prefix(3))) == nil)
        #expect(Self.feed(&c, trail)?.poc == 5)
    }

    @Test("an SPS with an out-of-range POC LSB width is not stored")
    func rejectsOversizedLsbWidth() {
        var c = HEVCPictureOrderCount()
        // log2_max_pic_order_cnt_lsb_minus4 = 13 (> 12) is outside what the spec allows
        c.feedParameterSets([B.sps(pocLsbBits: 17), B.pps()])
        #expect(Self.feed(&c, B.slice(type: T.idrNLP, pocLsbBits: 17)) == nil)
    }

    @Test("parameter set ids beyond the spec's 15 (SPS) and 63 (PPS) are not stored")
    func rejectsOutOfRangeParameterSetIDs() {
        var c = HEVCPictureOrderCount()
        c.feedParameterSets([B.sps(id: 16, pocLsbBits: 8), B.pps(id: 1, spsID: 16), B.pps(id: 64, spsID: 0),
                             B.sps(id: 0, pocLsbBits: 8)])
        #expect(Self.feed(&c, B.slice(type: T.idrNLP, ppsID: 1, pocLsbBits: 8)) == nil, "PPS 1 names SPS 16")
        #expect(Self.feed(&c, B.slice(type: T.idrNLP, ppsID: 64, pocLsbBits: 8)) == nil, "PPS 64 was not stored")
        c.feedParameterSets([B.pps(id: 63, spsID: 15), B.sps(id: 15, pocLsbBits: 8)])
        #expect(Self.feed(&c, B.slice(type: T.idrNLP, ppsID: 63, pocLsbBits: 8)) == .init(poc: 0, startsSequence: true))
    }
}

private extension Array where Element == UInt8 {
    /// Every run of three consecutive bytes.
    var windows3: [[UInt8]] {
        guard count >= 3 else { return [] }
        return (0...(count - 3)).map { Array(self[$0..<$0 + 3]) }
    }
}
