import Foundation
@testable import AetherEngine

/// Hand-built HEVC parameter sets and slice segment headers, just deep enough for
/// `HEVCPictureOrderCount` and `DualLayerPictureAlignment` to read: no picture data, no real
/// profile. Every field the reader consumes is written from a named argument, so a test states
/// the stream it means (POC LSB width, extra slice header bits, output flag, colour planes) and
/// the expected POC follows from the spec, not from running the code under test.
enum HEVCSyntheticBitstream {

    /// MSB-first bit writer with Exp-Golomb.
    struct BitWriter {
        private(set) var bits: [UInt8] = []

        mutating func u(_ value: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append(UInt8((value >> i) & 1)) }
        }
        mutating func flag(_ on: Bool) { bits.append(on ? 1 : 0) }
        mutating func ue(_ value: Int) {
            let v = value + 1
            let width = Int.bitWidth - v.leadingZeroBitCount
            u(0, width - 1)
            u(v, width)
        }
        /// The bytes written so far, padded with a stop bit and zeros to a byte boundary
        /// (rbsp_trailing_bits), followed by `tail` verbatim.
        func rbsp(tail: [UInt8] = []) -> [UInt8] {
            var all = bits
            all.append(1)
            while all.count % 8 != 0 { all.append(0) }
            var out: [UInt8] = []
            for i in stride(from: 0, to: all.count, by: 8) {
                out.append(all[i..<i + 8].reduce(0) { ($0 << 1) | $1 })
            }
            return out + tail
        }
    }

    /// Inserts emulation prevention bytes (00 00 {00..03} becomes 00 00 03 {..}).
    static func escape(_ rbsp: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for b in rbsp {
            if zeros >= 2 && b <= 3 { out.append(3); zeros = 0 }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// NAL unit: 2-byte header, then the escaped payload.
    static func nal(type: Int, temporalId: Int = 0, rbsp: [UInt8]) -> [UInt8] {
        [UInt8(type << 1), UInt8(temporalId + 1)] + escape(rbsp)
    }

    static func sps(id: Int = 0, pocLsbBits: Int = 8, chromaFormatIdc: Int = 1,
                    separateColourPlane: Bool = false, subLayers: Int = 1) -> [UInt8] {
        var w = BitWriter()
        w.u(0, 4)                         // sps_video_parameter_set_id
        w.u(subLayers - 1, 3)             // sps_max_sub_layers_minus1
        w.flag(true)                      // temporal_id_nesting
        w.u(0, 2); w.flag(false); w.u(2, 5)   // profile_space, tier, profile_idc (Main 10)
        w.u(0x20000000, 32)               // compatibility flags
        w.u(0, 48)                        // constraint flags: a long run of zero bytes, which is what
                                          // makes emulation prevention show up in every SPS
        w.u(120, 8)                       // general_level_idc
        for _ in 0..<(subLayers - 1) { w.flag(false); w.flag(false) }   // sub_layer profile/level absent
        if subLayers > 1 { w.u(0, 2 * (8 - (subLayers - 1))) }
        w.ue(id)
        w.ue(chromaFormatIdc)
        if chromaFormatIdc == 3 { w.flag(separateColourPlane) }
        w.ue(3840); w.ue(2160)
        w.flag(false)                     // conformance_window_flag
        w.ue(2); w.ue(2)                  // bit depths (10)
        w.ue(pocLsbBits - 4)              // log2_max_pic_order_cnt_lsb_minus4
        return nal(type: 33, rbsp: w.rbsp(tail: [0x40]))
    }

    static func pps(id: Int = 0, spsID: Int = 0, outputFlagPresent: Bool = false,
                    extraSliceHeaderBits: Int = 0) -> [UInt8] {
        var w = BitWriter()
        w.ue(id); w.ue(spsID)
        w.flag(false)                     // dependent_slice_segments_enabled_flag
        w.flag(outputFlagPresent)
        w.u(extraSliceHeaderBits, 3)
        return nal(type: 34, rbsp: w.rbsp(tail: [0x40]))
    }

    /// First (or later) slice segment of a picture. `pocLsb` is ignored for IDR (19, 20), which
    /// carry none. `tail` stands in for the rest of the header and the slice data.
    static func slice(type: Int, temporalId: Int = 0, firstSliceSegment: Bool = true,
                      ppsID: Int = 0, extraBits: Int = 0, extraBitsValue: Int = 0,
                      outputFlag: Bool? = nil, colourPlane: Int? = nil,
                      pocLsb: Int = 0, pocLsbBits: Int = 8, afterPOC: (value: Int, bits: Int)? = nil,
                      tail: [UInt8] = [0xAA]) -> [UInt8] {
        var w = BitWriter()
        w.flag(firstSliceSegment)
        if (16...23).contains(type) { w.flag(false) }     // no_output_of_prior_pics_flag
        w.ue(ppsID)
        w.u(extraBitsValue, extraBits)                    // slice_reserved_flag[]
        w.ue(2)                                           // slice_type
        if let outputFlag { w.flag(outputFlag) }
        if let colourPlane { w.u(colourPlane, 2) }
        if type != 19 && type != 20 { w.u(pocLsb, pocLsbBits) }
        if let afterPOC { w.u(afterPOC.value, afterPOC.bits) }   // whatever header field follows
        return nal(type: type, temporalId: temporalId, rbsp: w.rbsp(tail: tail))
    }

    /// NAL type numbers used by the tests.
    enum T {
        static let trailN = 0, trailR = 1, tsaN = 2, radlN = 6, radlR = 7, raslN = 8, raslR = 9
        static let blaWLP = 16, blaWRADL = 17, blaNLP = 18, idrWRADL = 19, idrNLP = 20, cra = 21
        static let eos = 36, eob = 37
    }

    // MARK: - Access units for DualLayerPictureAlignment

    /// Length-prefixed (4 bytes) access unit.
    static func accessUnit(_ nals: [[UInt8]]) -> [UInt8] {
        nals.flatMap { n in
            [UInt8((n.count >> 24) & 0xFF), UInt8((n.count >> 16) & 0xFF), UInt8((n.count >> 8) & 0xFF), UInt8(n.count & 0xFF)] + n
        }
    }

    /// An enhancement-layer NAL as it rides in the base-layer packet: wrapped in NAL type 63.
    static func wrappedEL(_ inner: [UInt8]) -> [UInt8] { [UInt8(63 << 1), 0x01] + inner }
}
