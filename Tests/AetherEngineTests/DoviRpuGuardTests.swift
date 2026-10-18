import Testing
import Foundation
import Dovi
@testable import AetherEngine

/// libdovi aborts the process on a polynomial piece with linear interpolation. The guard must
/// see that coming for an RPU whose CRC is perfectly valid, and must not flag real ones.
@Suite(.offCooperativePoolOneLane)
struct DoviRpuGuardTests {

    struct BitWriter {
        var bits: [Bool] = []
        mutating func put(_ v: UInt64, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bits.append((v >> UInt64(i)) & 1 == 1) } }
        mutating func ue(_ v: UInt64) {
            let x = v + 1
            let len = 64 - x.leadingZeroBitCount
            put(0, len - 1); put(x, len)
        }
        mutating func se(_ v: Int64) { ue(v > 0 ? UInt64(2 * v - 1) : UInt64(-2 * v)) }
        /// An Exp-Golomb code with exactly `zeros` leading zeros and `rest` as its suffix, however large
        /// the value that makes (`ue` cannot write above 2^64 - 2). libdovi reads it as `rest + 2^zeros - 1`,
        /// wrapping: its release build masks a shift by 64, so 64 zeros read as just `rest`.
        mutating func ueRaw(zeros: Int, rest: UInt64) {
            put(0, zeros); put(1, 1); put(rest, zeros)
        }
        var bytes: [UInt8] {
            var out = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
            for (i, b) in bits.enumerated() where b { out[i >> 3] |= UInt8(0x80 >> (i & 7)) }
            return out
        }
    }

    static func crc(_ data: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c ^= UInt32(byte) << 24
            for _ in 0..<8 { c = c & 0x8000_0000 != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        }
        return c
    }

    enum Piece {
        case polynomial, mmr
        /// A polynomial piece with `linear_interp_flag` set, which libdovi 3.4 cannot represent.
        case linear
    }

    enum Residual {
        /// Profile 8 shape: `disable_residual_flag` set, no NLQ.
        case none
        /// Profile 7 with the minimal enhancement layer's NLQ values.
        case mel
        /// Profile 7 with non-trivial NLQ values.
        case fel
    }

    /// A structurally valid RPU with a valid CRC, one entry of `pieces` per component (luma, Cb, Cr),
    /// each listing that curve's pieces in order. No DM metadata, so the mapping is all there is to parse
    /// and to write back. Residual-free by default (profile 8 shape); `residual` makes it a Profile 7 RPU.
    /// One display-management payload: the ids, the optional fixed fields, then the CM v2.9 list and the
    /// CM v4.0 list. Each list holds at most one block (zero payload bytes) followed, in the v4.0 list, by
    /// the mandatory level 254 block.
    struct DMPayload {
        /// `reserved_zero_3bits == 1`: only the three ids precede the block lists. Otherwise the 509-bit
        /// fixed field set of `VdrDmData::parse` follows them.
        var compressed = true
        var currentDmMetadataId: ((inout BitWriter) -> Void)?
        /// The declared CM v2.9 block count, used only when `cmv29Block` is nil (no block follows it).
        var cmv29Count: UInt64 = 0
        var cmv29Block: (length: UInt64, level: UInt64)?
        var cmv40Block: (length: UInt64, level: UInt64)?
    }

    static func writeDM(_ w: inout BitWriter, _ dm: DMPayload) {
        w.ue(0)                                  // affected_dm_metadata_id
        if let id = dm.currentDmMetadataId { id(&w) } else { w.ue(0) }
        w.ue(0)                                  // scene_refresh_flag
        if !dm.compressed {                      // 509 bits, valid per libdovi's validate
            for _ in 0..<9 { w.put(0, 16) }      // ycc_to_rgb_coef
            for _ in 0..<3 { w.put(0, 32) }      // ycc_to_rgb_offset
            for _ in 0..<9 { w.put(0, 16) }      // rgb_to_lms_coef
            w.put(65535, 16); w.put(0, 16); w.put(0, 16); w.put(0, 32)   // signal_eotf (65535 with no params)
            w.put(10, 5); w.put(0, 2); w.put(0, 2); w.put(0, 2)          // depth, color space, chroma, range
            w.put(0, 12); w.put(0, 12); w.put(0, 10)                     // min/max pq, diagonal
        }
        if let block = dm.cmv29Block {
            w.ue(1)
            while w.bits.count % 8 != 0 { w.bits.append(false) }
            w.ue(block.length); w.put(block.level, 8)
            for _ in 0..<block.length { w.put(0, 8) }
            // No alignment after the block: the next list's count follows it bit for bit.
        } else {
            w.ue(dm.cmv29Count)
            while w.bits.count % 8 != 0 { w.bits.append(false) }
        }
        if let block = dm.cmv40Block {
            w.ue(2)
            while w.bits.count % 8 != 0 { w.bits.append(false) }
            w.ue(block.length); w.put(block.level, 8)
            for _ in 0..<block.length { w.put(0, 8) }
            w.ue(2); w.put(254, 8)               // the required level 254 block
            for _ in 0..<2 { w.put(0, 8) }
        } else {
            w.ue(0)
        }
        while w.bits.count % 8 != 0 { w.bits.append(false) }
    }

    /// `body` is the payload after the 0x19 prefix: CRC, final byte and emulation prevention are added.
    static func seal(_ payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [0x19] + payload
        let crc = crc(body[1...])
        body += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF), 0x80]
        return escape(body)
    }

    /// `body` is 0x19, the payload, the CRC and the final byte; the NAL header, emulation prevention and
    /// the padding are added.
    static func escape(_ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x7C, 0x01]
        var zeros = 0
        for b in body {
            if zeros >= 2 && b <= 3 { out.append(3); zeros = 0 }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        // libdovi refuses an input under 25 bytes before it looks at anything else; trailing zero bytes
        // are trimmed by both it and the guard, so they pad a short RPU without changing it.
        while out.count < 26 { out.append(0) }
        return out
    }

    /// `coefficientDataType` 1 (32-bit coefficients, no integer part, no denominator) is residual-free only.
    /// `pivotCount` replaces luma's `num_pivots_minus2` (the pivots written stay the real ones),
    /// `firstMappingIdc` the encoding of luma's first `mapping_idc`, `vdrRpuId` the mapping's id and `dm`
    /// appends a display-management payload after the mapping and NLQ.
    static func craft(pieces: [[Piece]], residual: Residual = .none, coefficientDataType: Int = 0,
                      pivotCount: UInt64? = nil, firstMappingIdc: ((inout BitWriter) -> Void)? = nil,
                      vdrRpuId: ((inout BitWriter) -> Void)? = nil, dm: DMPayload? = nil) -> [UInt8] {
        precondition(coefficientDataType == 0 || residual == .none)
        var w = BitWriter()
        w.put(2, 6); w.put(18, 11)           // rpu_type, rpu_format (libdovi checks the 0x08 0x09 start)
        w.put(1, 4); w.put(0, 4)             // vdr_rpu_profile 1, level 0
        w.put(1, 1)                          // vdr_seq_info_present
        w.put(0, 1); w.put(UInt64(coefficientDataType), 2)   // chroma filter flag, coefficient_data_type
        if coefficientDataType == 0 { w.ue(23) }             // denom
        w.put(0, 2); w.put(0, 1)             // normalized idc, full range
        w.ue(2); w.ue(2); w.ue(4)            // bl, el, vdr depth - 8
        w.put(0, 1)                          // spatial resampling flag
        w.put(dm?.compressed == true ? 1 : 0, 3)   // reserved_zero_3bits, 1 selects compressed DM data
        w.put(residual == .none ? 0 : 1, 1)  // el_spatial_resampling_filter_flag (with the residual: profile 7)
        w.put(residual == .none ? 1 : 0, 1)  // disable_residual
        w.put(dm == nil ? 0 : 1, 1)          // vdr_dm_metadata_present
        w.put(0, 1)                          // use_prev_vdr_rpu
        if let vdrRpuId { vdrRpuId(&w) } else { w.ue(0) }
        w.ue(0); w.ue(0)                     // color space, chroma format
        for (c, curve) in pieces.enumerated() {
            if c == 0, let pivotCount { w.ue(pivotCount) } else { w.ue(UInt64(curve.count) - 1) }   // num_pivots_minus2
            for k in 0...curve.count { w.put(UInt64(k * 1023 / curve.count), 10) }
        }
        if residual != .none { w.put(0, 3); w.put(0, 10); w.put(1023, 10) }   // NLQ method, pivots
        w.ue(0); w.ue(0)                     // partitions
        /// One coefficient: signed integer part and 23 fraction bits, or (type 1) 32 plain bits.
        func coef(_ w: inout BitWriter, _ int: Int64) {
            if coefficientDataType == 0 { w.se(int); w.put(0, 23) } else { w.put(0, 32) }
        }
        for (c, curve) in pieces.enumerated() {
            for (k, piece) in curve.enumerated() {
                let idc = { (w: inout BitWriter, v: UInt64) in
                    if c == 0 && k == 0, let firstMappingIdc { firstMappingIdc(&w) } else { w.ue(v) }
                }
                switch piece {
                case .mmr:
                    idc(&w, 1); w.put(0, 2)  // MMR, order 1
                    coef(&w, 0)
                    for _ in 0..<7 { coef(&w, 0) }
                case .linear:
                    idc(&w, 0); w.ue(0); w.put(1, 1)
                case .polynomial:
                    idc(&w, 0)               // polynomial
                    w.ue(0)                  // poly_order_minus1
                    w.put(0, 1)              // linear_interp_flag
                    for k in 0..<2 { coef(&w, k == 1 ? 1 : 0) }
                }
            }
        }
        if residual != .none {
            for c in 0..<3 {                 // NLQ parameters; all zero but vdr_in_max_int is the MEL signature
                let fel = residual == .fel
                w.put(fel ? UInt64(40 + 8 * c) : 0, 10)
                w.ue(fel ? 0 : 1); w.put(fel ? 1 << 20 : 0, 23)
                w.ue(0); w.put(fel ? 3 << 18 : 0, 23)
                w.ue(0); w.put(fel ? 1 << 19 : 0, 23)
            }
        }
        if let dm { writeDM(&w, dm) }
        while w.bits.count % 8 != 0 { w.bits.append(false) }
        return seal(w.bytes)
    }

    /// One piece per component, polynomial unless named: the shape most tests here build.
    static func craft(linearOnComponent: Int?, mmrOnComponent: Int? = nil) -> [UInt8] {
        craft(pieces: (0..<3).map { c in
            [c == linearOnComponent ? Piece.linear : c == mmrOnComponent ? .mmr : .polynomial]
        })
    }

    /// `nal` with one bit of its stored CRC32 flipped (`crcByte` 0 is the first CRC byte) or, for
    /// `payloadByte`, one bit of the payload flipped under the CRC that was computed for the original.
    static func withBadCRC(_ nal: [UInt8], crcByte: Int? = nil, payloadByte: Int? = nil) -> [UInt8] {
        var u: [UInt8] = []
        var zeros = 0
        for b in nal {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            u.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        while u.last == 0 { u.removeLast() }
        var body = Array(u.dropFirst(2))   // 0x19, payload, crc32(4), 0x80
        if let crcByte { body[body.count - 5 + crcByte] ^= 0x01 }
        if let payloadByte { body[1 + payloadByte] ^= 0x10 }
        return escape(body)
    }

    static func verdict(_ nal: [UInt8]) -> (crc: Bool, flagged: Bool) {
        nal.withUnsafeBufferPointer { p in
            guard let u = DoviRpuGuard.verifiedUnescaped(p.baseAddress!, p.count) else { return (false, false) }
            return (true, DoviRpuGuard.reachesUnimplementedPath(u))
        }
    }

    @Test("a crafted structurally valid RPU parses in libdovi, so the scanner is tracking a real layout")
    func craftedBaselineParses() {
        let nal = Self.craft(linearOnComponent: nil)
        #expect(Self.verdict(nal) == (true, false))
        let rpu = nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) }
        #expect(rpu != nil, "libdovi should accept the crafted RPU")
        if let rpu {
            // A handle comes back even on a parse failure; the error is what says it was accepted.
            #expect(dovi_rpu_get_error(rpu) == nil, "\(dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "")")
            dovi_rpu_free(rpu)
        }
    }

    @Test("an RPU whose CRC is wrong is refused before libdovi sees it",
          arguments: [(0 as Int?, nil as Int?), (3, nil), (nil, 0), (nil, 10)])
    func badCRCIsRefused(crcByte: Int?, payloadByte: Int?) {
        let good = Self.craft(linearOnComponent: nil)
        Self.expectAccepted(good)
        let bad = Self.withBadCRC(good, crcByte: crcByte, payloadByte: payloadByte)
        #expect(bad != good)
        #expect(Self.verdict(bad) == (false, false))
        #expect(bad.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) } == nil)
        // The CRC is checked before the scan, so a hostile RPU with a wrong CRC is refused on the CRC.
        let hostile = Self.withBadCRC(Self.craft(linearOnComponent: 1), crcByte: 2)
        #expect(Self.verdict(hostile) == (false, false))
        #expect(hostile.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) } == nil)
    }

    @Test("an MMR piece is walked past without a false positive")
    func mmrIsSkipped() {
        for c in 0..<3 {
            let nal = Self.craft(linearOnComponent: nil, mmrOnComponent: c)
            #expect(Self.verdict(nal) == (true, false), "MMR on component \(c)")
        }
    }

    @Test("linear interpolation on any component is caught before libdovi sees it",
          arguments: [0, 1, 2])
    func linearInterpIsRejected(component: Int) {
        let nal = Self.craft(linearOnComponent: component)
        #expect(Self.verdict(nal) == (true, true))
        let rpu = nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) }
        #expect(rpu == nil)
    }

    @Test("linear interpolation after an MMR piece is still caught")
    func linearAfterMmr() {
        // MMR on component 0, linear on component 2
        let nal = Self.craft(linearOnComponent: 2, mmrOnComponent: 0)
        #expect(Self.verdict(nal) == (true, true))
        #expect(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) } == nil)
    }

    /// A Profile 8-shaped RPU with `use_prev_vdr_rpu_flag` set and DM metadata: no mapping follows the
    /// header, only the DM payload. `cmv40Block` is one (length, level) extended block followed by the
    /// mandatory level 254 block, `cmv29Count` the declared CM v2.9 block count (no blocks follow it, so only 0 parses).
    /// `prevRpuId` replaces the `prev_vdr_rpu_id` encoding.
    static func craftUsePrev(cmv29Count: UInt64 = 0, cmv29Block: (length: UInt64, level: UInt64)? = nil,
                             cmv40Block: (length: UInt64, level: UInt64)?, compressed: Bool = true,
                             currentDmMetadataId: ((inout BitWriter) -> Void)? = nil,
                             prevRpuId: ((inout BitWriter) -> Void)? = nil) -> [UInt8] {
        var w = BitWriter()
        w.put(2, 6); w.put(18, 11)
        w.put(1, 4); w.put(0, 4)
        w.put(1, 1)
        w.put(0, 1); w.put(0, 2)
        w.ue(23)
        w.put(0, 2); w.put(0, 1)
        w.ue(2); w.ue(2); w.ue(4)
        w.put(0, 1); w.put(compressed ? 1 : 0, 3); w.put(0, 1)   // reserved_zero_3bits == 1 selects compressed DM data
        w.put(1, 1)                          // disable_residual
        w.put(1, 1)                          // vdr_dm_metadata_present
        w.put(1, 1)                          // use_prev_vdr_rpu
        if let prevRpuId { prevRpuId(&w) } else { w.ue(0) }   // prev_vdr_rpu_id
        writeDM(&w, DMPayload(compressed: compressed, currentDmMetadataId: currentDmMetadataId,
                              cmv29Count: cmv29Count, cmv29Block: cmv29Block, cmv40Block: cmv40Block))
        return seal(w.bytes)
    }

    @Test("a use_prev RPU with valid DM blocks parses in libdovi and is not flagged")
    func usePrevBaselineParses() {
        let nal = Self.craftUsePrev(cmv40Block: (10, 8))
        #expect(Self.verdict(nal) == (true, false))
        let rpu = nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) }
        #expect(rpu != nil)
        if let rpu {
            #expect(dovi_rpu_get_error(rpu) == nil, "\(dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "")")
            dovi_rpu_free(rpu)
        }
    }

    @Test("use_prev does not skip the DM check: an invalid level 8 length is caught")
    func usePrevInvalidLevel8Length() {
        let nal = Self.craftUsePrev(cmv40Block: (11, 8))
        #expect(Self.verdict(nal) == (true, true))
        let rpu = nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) }
        #expect(rpu == nil)
    }

    @Test("use_prev does not skip the DM check: an oversized extended block count is caught")
    func usePrevHugeBlockCount() {
        let nal = Self.craftUsePrev(cmv29Count: 1 << 30, cmv40Block: nil)
        #expect(Self.verdict(nal) == (true, true))
        let rpu = nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) }
        #expect(rpu == nil)
    }

    // MARK: - Hostile encodings and the display-management walk

    /// The guard refuses `nal`: CRC-valid, flagged, and `parse` answers nil without calling libdovi.
    /// Never call libdovi directly on an RPU passed here: it is built panic=abort and the ones these
    /// tests build reach a panic or an allocation abort in it.
    static func expectRejected(_ nal: [UInt8], _ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(verdict(nal) == (true, true), Comment(rawValue: note), sourceLocation: sourceLocation)
        #expect(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) } == nil,
                Comment(rawValue: note), sourceLocation: sourceLocation)
    }

    /// The guard lets `nal` through and libdovi parses it without an error (parsing alone is safe for
    /// these; they are not hostile).
    static func expectAccepted(_ nal: [UInt8], _ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(verdict(nal) == (true, false), Comment(rawValue: note), sourceLocation: sourceLocation)
        let rpu = nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) }
        #expect(rpu != nil, Comment(rawValue: note), sourceLocation: sourceLocation)
        if let rpu {
            #expect(dovi_rpu_get_error(rpu) == nil,
                    Comment(rawValue: "\(note) \(dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "")"),
                    sourceLocation: sourceLocation)
            dovi_rpu_free(rpu)
        }
    }

    /// The largest suffix an Exp-Golomb code with `zeros` leading zeros can carry.
    static func maxRest(_ zeros: Int) -> UInt64 { zeros >= 64 ? .max : (1 << UInt64(zeros)) - 1 }

    @Test("a mapping_idc coded with 64 leading zeros is rejected, not misread as rest - 1")
    func mappingIdcWithSixtyFourLeadingZeros() {
        // libdovi's release-mode `read_ue` masks the shift `1 << 64` to `1 << 0`, so it reads this code as
        // rest = 0, i.e. mapping_idc 0 (polynomial), then poly_order_minus1 0 and the linear flag: the
        // `unimplemented!()` abort. A plain Swift shift gives 0 and `0 - 1` wrapped is not 0 or 1, so a
        // scan that trusted it walked away from the RPU and let it through.
        let nal = Self.craft(pieces: [[.linear], [.polynomial], [.polynomial]],
                             firstMappingIdc: { $0.ueRaw(zeros: 64, rest: 0) })
        Self.expectRejected(nal)
    }

    @Test("an Exp-Golomb code of 32 or more leading zeros is rejected wherever the scan reads one",
          arguments: [32, 33, 48, 64])
    func oversizeExpGolombIsRejected(zeros: Int) {
        let rest = Self.maxRest(zeros)
        // current_dm_metadata_id is written back as is by the conversion: write_ue(u64::MAX) unary-codes
        // 2^32 - 1 zeros, a ~0.5 GB allocation. prev_vdr_rpu_id (header) and vdr_rpu_id (mapping) are
        // written the same way and, like the DM id, not range-checked by libdovi.
        Self.expectRejected(Self.craftUsePrev(cmv40Block: nil, currentDmMetadataId: { $0.ueRaw(zeros: zeros, rest: rest) }),
                            "current_dm_metadata_id")
        Self.expectRejected(Self.craftUsePrev(cmv40Block: nil, prevRpuId: { $0.ueRaw(zeros: zeros, rest: rest) }),
                            "prev_vdr_rpu_id")
        Self.expectRejected(Self.craft(pieces: [[.polynomial], [.polynomial], [.polynomial]], vdrRpuId: { $0.ueRaw(zeros: zeros, rest: rest) }),
                            "vdr_rpu_id")
        Self.expectRejected(Self.craft(pieces: [[.polynomial], [.polynomial], [.polynomial]],
                                       firstMappingIdc: { $0.ueRaw(zeros: zeros, rest: rest) }),
                            "mapping_idc")
    }

    @Test("an Exp-Golomb code just under the bound (31 leading zeros) is still read normally")
    func largestInBoundExpGolombIsAccepted() {
        let nal = Self.craftUsePrev(cmv40Block: nil, currentDmMetadataId: { $0.ueRaw(zeros: 31, rest: Self.maxRest(31)) })
        Self.expectAccepted(nal)
    }

    @Test("a pivot count the payload cannot hold is rejected before libdovi sizes its vectors from it",
          arguments: [UInt64(1) << 31, (UInt64(1) << 32) - 2])
    func pivotCountBeyondPayload(count: UInt64) {
        // libdovi allocates `vec![0; num_pivots_minus2 + 2]` per curve before it reads one pivot.
        Self.expectRejected(Self.craft(pieces: [[.polynomial], [.polynomial], [.polynomial]], pivotCount: count))
    }

    @Test("an uncompressed DM payload is skipped by its 509 fixed bits and the blocks behind it are checked")
    func uncompressedDmPayload() {
        // VdrDmData::parse reads three ids then 509 bits of fixed fields; the guard must land exactly on
        // the CM v2.9 block count behind them, or the level 8 block below is never seen.
        Self.expectAccepted(Self.craftUsePrev(cmv40Block: (10, 8), compressed: false), "valid level 8, uncompressed")
        Self.expectRejected(Self.craftUsePrev(cmv40Block: (11, 8), compressed: false), "level 8 length 11, uncompressed")
    }

    @Test("a non-empty CM v2.9 block list is walked to the CM v4.0 list behind it")
    func cmv29BlockWalk() {
        // Level 1 is a 5-byte CM v2.9 block.
        Self.expectAccepted(Self.craftUsePrev(cmv29Block: (5, 1), cmv40Block: (10, 8)), "valid")
        Self.expectRejected(Self.craftUsePrev(cmv29Block: (5, 1), cmv40Block: (11, 8)), "level 8 length 11 behind a level 1 block")
        Self.expectRejected(Self.craftUsePrev(cmv29Block: (5, 1), cmv40Block: (11, 8), compressed: false), "same, uncompressed")
    }

    @Test("level 9 and level 10 blocks of an undefined length are rejected, the defined ones are not",
          arguments: [(1, 9, true), (17, 9, true), (0, 9, false), (2, 9, false), (16, 9, false), (18, 9, false),
                      (5, 10, true), (21, 10, true), (0, 10, false), (4, 10, false), (6, 10, false), (20, 10, false)])
    func level9And10Lengths(length: Int, level: Int, valid: Bool) {
        // `required_bits()` is `unreachable!()` for any other length, and the parser only compares the
        // length with the block's own, so libdovi aborts after a clean parse.
        let nal = Self.craftUsePrev(cmv40Block: (UInt64(length), UInt64(level)))
        if valid {
            Self.expectAccepted(nal, "level \(level) length \(length)")
        } else {
            Self.expectRejected(nal, "level \(level) length \(length)")
        }
    }

    @Test("level 8 lengths: the five defined ones pass, their neighbours are rejected",
          arguments: [(10, true), (12, true), (13, true), (19, true), (25, true),
                      (0, false), (11, false), (14, false), (20, false), (24, false), (26, false)])
    func level8Lengths(length: Int, valid: Bool) {
        let nal = Self.craftUsePrev(cmv40Block: (UInt64(length), 8))
        if valid { Self.expectAccepted(nal, "length \(length)") } else { Self.expectRejected(nal, "length \(length)") }
    }

    @Test("coefficient_data_type 1 (32-bit coefficients, no integer parts): the walk stays in step")
    func coefficientDataTypeOne() {
        // With type 1 libdovi reads 32 bits per coefficient and no signed integer part; a scan that kept
        // the type-0 layout would drift and miss the linear piece on the last component.
        let ok = Self.craft(pieces: [[.polynomial], [.mmr], [.mmr]], coefficientDataType: 1)
        Self.expectAccepted(ok)
        for component in 0..<3 {
            var pieces: [[Piece]] = [[.polynomial], [.mmr], [.mmr]]
            pieces[component] = [.linear]
            Self.expectRejected(Self.craft(pieces: pieces, coefficientDataType: 1), "linear on component \(component)")
        }
        Self.expectRejected(Self.craft(pieces: [[.polynomial, .mmr], [.mmr], [.mmr]], coefficientDataType: 1), "mixed curve")
    }

    @Test("a Profile 7 RPU's NLQ parameters are walked to the DM payload behind them",
          arguments: [Residual.mel, .fel], [true, false])
    func nlqFollowedByDm(residual: Residual, compressed: Bool) throws {
        let pieces: [[Piece]] = [[.polynomial], [.mmr], [.mmr]]
        func dm(_ length: UInt64) -> DMPayload { DMPayload(compressed: compressed, cmv40Block: (length, 8)) }
        let good = Self.craft(pieces: pieces, residual: residual, dm: dm(10))
        Self.expectAccepted(good, "\(residual) compressed \(compressed)")
        // The DM survives the conversion and write like production does.
        let written = try #require(Self.convertedBytes(good))
        #expect(!written.isEmpty)
        Self.expectRejected(Self.craft(pieces: pieces, residual: residual, dm: dm(11)),
                            "level 8 length 11, \(residual) compressed \(compressed)")
    }

    // MARK: - Write path

    /// What production does with an RPU the guard let through: `DoviRpuConverter.convertedUnspec62`, the
    /// mode 2 conversion and the write. nil when the guard or libdovi refuses; reaching the end at all is
    /// the assertion, because libdovi is built panic=abort and a panic here kills the test process.
    static func convertedBytes(_ nal: [UInt8]) -> [UInt8]? {
        guard let rpu = nal.withUnsafeBufferPointer({ DoviRpuGuard.parse($0.baseAddress!, $0.count) }) else { return nil }
        defer { dovi_rpu_free(rpu) }
        guard let out = DoviRpuConverter.convertedUnspec62(rpu) else { return nil }
        defer { dovi_data_free(out) }
        guard let data = out.pointee.data else { return nil }
        return [UInt8](UnsafeBufferPointer(start: data, count: out.pointee.len))
    }

    @Test("a curve that mixes polynomial and MMR pieces is rejected: the writer indexes the polynomial list per piece",
          arguments: [0, 1, 2], [true, false])
    func mixedCurveIsRejected(component: Int, polynomialFirst: Bool) {
        var pieces = [[Piece]](repeating: [.polynomial], count: 3)
        pieces[component] = polynomialFirst ? [.polynomial, .mmr] : [.mmr, .polynomial]
        for residual in [Residual.none, .mel, .fel] {
            let nal = Self.craft(pieces: pieces, residual: residual)
            #expect(Self.verdict(nal) == (true, true), "component \(component), residual \(residual)")
            #expect(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) } == nil)
        }
    }

    @Test("the same pieces without the mix are accepted, and convert and write like production does",
          arguments: [Residual.none, .mel, .fel])
    func unmixedMultiPieceCurvesConvertAndWrite(residual: Residual) throws {
        for pieces in [
            [[Piece.polynomial, .polynomial], [.polynomial, .polynomial], [.polynomial, .polynomial]],
            [[.polynomial, .polynomial], [.mmr, .mmr], [.mmr, .mmr]],
            [[.polynomial], [.mmr], [.mmr]],
        ] {
            let nal = Self.craft(pieces: pieces, residual: residual)
            #expect(Self.verdict(nal) == (true, false), "\(pieces)")
            let written = try #require(Self.convertedBytes(nal), "\(pieces)")
            // The output is a Profile 8.1 RPU libdovi itself reads back.
            let reread = written.withUnsafeBufferPointer { dovi_parse_unspec62_nalu($0.baseAddress!, $0.count) }
            defer { reread.map { dovi_rpu_free($0) } }
            #expect(reread != nil && dovi_rpu_get_error(reread) == nil, "\(pieces)")
        }
    }

    @Test("a crafted Profile 7 RPU is classified from its NLQ values and converts to 8.1",
          arguments: [Residual.mel, .fel])
    func craftedProfile7Classification(residual: Residual) throws {
        let nal = Self.craft(pieces: [[.polynomial], [.mmr], [.mmr]], residual: residual)
        let rpu = try #require(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) })
        defer { dovi_rpu_free(rpu) }
        #expect(dovi_rpu_get_error(rpu) == nil)
        let header = try #require(dovi_rpu_get_header(rpu))
        defer { dovi_rpu_free_header(header) }
        let elType = String(cString: try #require(header.pointee.el_type))
        #expect(elType == (residual == .fel ? "FEL" : "MEL"))
        #expect(Self.convertedBytes(nal) != nil)
    }

    @Test("real RPUs from the FEL fixtures are never flagged",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[2]), DoviFelRealFileTests.needsClips))
    func realRpusPass() throws {
        let seed = try #require(try DoviFelFuzzTests.seed())
        #expect(Self.verdict(seed.rpu) == (true, false))
    }
}
