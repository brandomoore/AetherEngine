// Annex-B HEVC samples converted by the session muxer instead of movenc (PR #703, MovieClaw P38).
//
// movenc's own conversion under `hvc1` drops every in-band VPS/SPS/PPS, so a stream that sends a new
// PPS mid-title has its later slices decoded against the stale one. The converter must keep every NAL.
import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

@Suite("Annex-B samples keep their in-band parameter sets (PR #703)")
struct AnnexBSampleConverterTests {

    private let aud: [UInt8] = [0x46, 0x01, 0x50]
    private let vps: [UInt8] = [0x40, 0x01, 0x0C]
    private let pps: [UInt8] = [0x44, 0x01, 0xC0, 0x72]
    /// An IDR slice carrying an emulation-prevention byte, which must pass through untouched.
    private let idr: [UInt8] = [0x28, 0x01, 0xAF, 0x00, 0x00, 0x03, 0x01, 0x80]

    private func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        nals.flatMap { nal -> [UInt8] in
            let n = nal.count
            return [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + nal
        }
    }

    /// Run the packet-level conversion on a fresh packet holding `bytes`; nil when it declined.
    private func convert(_ bytes: [UInt8]) -> [UInt8]? {
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let pkt = packet, av_new_packet(pkt, Int32(bytes.count)) == 0 else { return nil }
        bytes.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress, bytes.count) }
        guard AnnexBSampleConverter.convertToLengthPrefixed(pkt) else { return nil }
        return Array(UnsafeBufferPointer(start: pkt.pointee.data, count: Int(pkt.pointee.size)))
    }

    @Test("Every NAL survives, parameter sets included, and start-code zero padding is dropped")
    func keepsParameterSets() {
        let annexB: [UInt8] = [0, 0, 0, 1] + aud + [0, 0, 1] + vps + [0, 0, 0, 1] + pps
            + [0, 0, 1] + idr + [0, 0]
        #expect(convert(annexB) == lengthPrefixed([aud, vps, pps, idr]))
    }

    @Test("A sample with no start code is declined and left as it was")
    func lengthPrefixedInputDeclined() {
        #expect(convert(lengthPrefixed([idr])) == nil)
    }

    @Test("A NAL in the 256 to 511 byte band is converted once, not split at its own length bytes")
    func midSizedNAL() {
        // Its length prefix would read 00 00 01 xx, but the input here is Annex B, so the only start
        // codes are the real ones and the payload contains none.
        let slice: [UInt8] = [0x02, 0x01] + [UInt8](repeating: 0x55, count: 300)
        let annexB: [UInt8] = [0, 0, 0, 1] + pps + [0, 0, 0, 1] + slice
        #expect(convert(annexB) == lengthPrefixed([pps, slice]))
    }

    @Test("The converted packet's buffer is a new one, the source buffer is not written")
    func sourceBufferUntouched() {
        let annexB: [UInt8] = [0, 0, 1] + pps + [0, 0, 1] + idr
        var source: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var shared: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&source); av_packet_free(&shared) }
        guard let src = source, let ref = shared, av_new_packet(src, Int32(annexB.count)) == 0 else {
            Issue.record("packet allocation failed"); return
        }
        annexB.withUnsafeBytes { _ = memcpy(src.pointee.data, $0.baseAddress, annexB.count) }
        #expect(av_packet_ref(ref, src) == 0)
        #expect(AnnexBSampleConverter.convertToLengthPrefixed(ref))
        #expect(Array(UnsafeBufferPointer(start: src.pointee.data, count: Int(src.pointee.size))) == annexB)
        #expect(Array(UnsafeBufferPointer(start: ref.pointee.data, count: Int(ref.pointee.size)))
            == lengthPrefixed([pps, idr]))
    }
}
