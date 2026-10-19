import Testing
@testable import AetherEngine

// A TrueHD track that starts after the probe window keeps AV_PROFILE_UNKNOWN, so the engine reads
// Atmos from the track's own major sync instead (John Wick: Chapter 2, TrueHD from 22 s).
@Suite("TrueHDMajorSync Atmos detection")
struct TrueHDMajorSyncTests {

    /// First 32 bytes of an access unit carrying a major sync, from a TrueHD Atmos remux:
    /// four substreams, substream_info 0xFC.
    static let atmosHead: [UInt8] = bytes("630fe8daf8726fba0017804fb752100000008a2a43fc00364aefe307e3011fc6")

    /// The same from FFmpeg's own TrueHD encoder (5.1, no Atmos): two substreams, substream_info 0x3C.
    static let plainHead: [UInt8] = bytes("d063ffd8f8726fba0007800fb752000000008c7f203c0000000000000000e4d1")

    /// An access unit without a major sync, eight bytes long (length field 4 words).
    static let syncless: [UInt8] = [0x20, 0x04, 0xE9, 0x28, 0x70, 0x23, 0x60, 0x7F]

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    static func verdict(_ packet: [UInt8]) -> Bool? {
        packet.withUnsafeBytes { TrueHDMajorSync.isAtmos($0) }
    }

    @Test func atmosMajorSyncReadsAtmos() {
        #expect(Self.verdict(Self.atmosHead) == true)
    }

    @Test func plainMajorSyncReadsNoAtmos() {
        #expect(Self.verdict(Self.plainHead) == false)
    }

    @Test func majorSyncInALaterAccessUnitOfThePacketIsFound() {
        #expect(Self.verdict(Self.syncless + Self.syncless + Self.atmosHead) == true)
    }

    @Test func packetWithoutMajorSyncHasNoVerdict() {
        #expect(Self.verdict(Self.syncless + Self.syncless) == nil)
        #expect(Self.verdict([]) == nil)
    }

    @Test func fourSubstreamsWithoutThePresentationBitIsNotAtmos() {
        var head = Self.atmosHead
        head[21] &= 0x7F
        #expect(Self.verdict(head) == false)
    }

    @Test func brokenSignatureIsNotAMajorSync() {
        var head = Self.atmosHead
        head[13] ^= 0xFF
        #expect(Self.verdict(head) == nil)
    }

    @Test func zeroLengthAccessUnitStopsTheWalk() {
        #expect(Self.verdict([0x00, 0x00, 0x00, 0x00] + Self.atmosHead) == nil)
    }
}
