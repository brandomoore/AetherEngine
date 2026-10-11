import Testing
import Foundation
@testable import AetherEngine

/// libavformat cannot write an APAC sample entry, so the spatial bridge muxes a stand-in and the
/// init segment has its sound entry swapped. The layout of that entry and the HLS codec string are
/// copied from what Apple's own writer produces and what AVPlayer accepts; these pin both.
@Suite("APAC sample entry and init rewrite")
struct APACSampleEntryTests {

    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + Array(type.utf8) + payload }
    private func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }

    @Test("codec string carries profile 31 and the channel-count level")
    func codecs() {
        #expect(APACSampleEntry.codecsString(channelCount: 8) == "apac.31.02")
        #expect(APACSampleEntry.codecsString(channelCount: 10) == "apac.31.03")
        #expect(APACSampleEntry.codecsString(channelCount: 12) == "apac.31.03")
        #expect(APACSampleEntry.codecsString(channelCount: 16) == "apac.31.04")
    }

    @Test("sample entry matches the AVAssetWriter layout: v0, 2 ch, 16 bit, rate, then dapa")
    func entryLayout() {
        let cookie = Data(box("dapa", [0, 0, 0, 0, 0xAB, 0xCD]))
        let e = [UInt8](APACSampleEntry.sampleEntry(magicCookie: cookie, sampleRate: 48_000))
        #expect(u32(e, 0) == e.count)
        #expect(String(bytes: e[4..<8], encoding: .ascii) == "apac")
        // Same 28 bytes AVAssetWriter wrote for 7.1.4 and 9.1.6 on macOS 27.
        #expect(e[8..<36].map { String(format: "%02x", $0) }.joined()
                == "000000000000000100000000000000000002001000000000bb800000")
        #expect(Array(e[36...]) == [UInt8](cookie))
    }

    @Test("the sound track's entry is replaced and every ancestor size follows")
    func rewrite() throws {
        let alac = box("alac", [UInt8](repeating: 0, count: 28) + box("alac", [UInt8](repeating: 1, count: 28)))
        let soundTrak = box("trak", box("tkhd", [UInt8](repeating: 0, count: 84))
            + box("mdia", box("mdhd", [UInt8](repeating: 0, count: 24))
                + box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("soun".utf8) + [UInt8](repeating: 0, count: 13))
                + box("minf", box("smhd", [0, 0, 0, 0, 0, 0, 0, 0])
                    + box("stbl", box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + alac) + box("stts", [0, 0, 0, 0, 0, 0, 0, 0])))))
        let videoTrak = box("trak", box("mdia", box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("vide".utf8) + [0])))
        let initBytes = Data(box("ftyp", Array("iso5".utf8) + [0, 0, 0, 1])
            + box("moov", box("mvhd", [UInt8](repeating: 0, count: 100)) + videoTrak + soundTrak + box("mvex", [])))
        let entry = APACSampleEntry.sampleEntry(magicCookie: Data(box("dapa", [UInt8](repeating: 7, count: 120))), sampleRate: 48_000)

        let out = try #require(APACSampleEntry.replacingSoundSampleEntry(in: initBytes, with: entry))
        let b = [UInt8](out)
        #expect(b.count == initBytes.count + entry.count - alac.count)
        // Walk the rewritten tree strictly: every box must fit its parent exactly.
        func children(_ start: Int, _ end: Int) -> [(String, Int, Int)] {
            var o = start, out: [(String, Int, Int)] = []
            while o < end { let s = u32(b, o); out.append((String(bytes: b[o + 4..<o + 8], encoding: .ascii)!, o, o + s)); o += s }
            #expect(o == end)
            return out
        }
        let top = children(0, b.count)
        #expect(top.map(\.0) == ["ftyp", "moov"])
        let moov = top[1]
        let inMoov = children(moov.1 + 8, moov.2)
        #expect(inMoov.map(\.0) == ["mvhd", "trak", "trak", "mvex"])
        let traks = inMoov.filter { $0.0 == "trak" }
        let sound = traks[1]
        let mdia = children(sound.1 + 8, sound.2).first { $0.0 == "mdia" }!
        let minf = children(mdia.1 + 8, mdia.2).first { $0.0 == "minf" }!
        let stbl = children(minf.1 + 8, minf.2).first { $0.0 == "stbl" }!
        let stsd = children(stbl.1 + 8, stbl.2).first { $0.0 == "stsd" }!
        let entries = children(stsd.1 + 16, stsd.2)
        #expect(entries.map(\.0) == ["apac"])
        #expect(Data(b[entries[0].1..<entries[0].2]) == entry)
    }

    @Test("a 64-bit box or a truncated init is refused, not misparsed")
    func oddBoxesAreRefused() {
        let entry = Data(box("apac", []))
        // size == 1: a largesize box, which movenc never writes for an init.
        let large = Data(be32(1) + Array("moov".utf8) + [0, 0, 0, 0, 0, 0, 0, 16])
        #expect(APACSampleEntry.replacingSoundSampleEntry(in: large, with: entry) == nil)
        let truncated = Data(box("moov", box("trak", [])).dropLast(3))
        #expect(APACSampleEntry.replacingSoundSampleEntry(in: truncated, with: entry) == nil)
        #expect(APACSampleEntry.replacingSoundSampleEntry(in: Data(), with: entry) == nil)
    }

    @Test("an init with no sound track is left for the caller to forward unchanged")
    func noSoundTrack() {
        let initBytes = Data(box("moov", box("trak", box("mdia", box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("vide".utf8))))))
        #expect(APACSampleEntry.replacingSoundSampleEntry(in: initBytes, with: Data(box("apac", []))) == nil)
    }

    @Test("the platform encoder yields sync packets, a dapa cookie and 2048 frames of priming")
    func encoder() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l714
        let encoder = try APACEncoder(layout: layout, bitRate: 4_000_000)
        #expect(String(bytes: encoder.magicCookie[4..<8], encoding: .ascii) == "dapa")
        #expect(encoder.leadingFrames == 2048)

        let frames = 48_000
        let planes = (0..<layout.channelCount).map { c -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0..<frames { p[i] = 0.2 * sinf(Float(i) * 0.01 * Float(c + 1)) }
            return p
        }
        defer { planes.forEach { $0.deallocate() } }
        var packets = try encoder.encode(planes: planes.map { UnsafePointer($0) }, frameCount: frames)
        packets += try encoder.flush()
        // 48000 input frames + 2048 priming, in 1024-frame packets, rounded up by the tail.
        #expect(packets.count == (frames + encoder.leadingFrames + 1023) / 1024)
        #expect(packets.allSatisfy { $0.isSync })
        #expect(packets.allSatisfy { !$0.data.isEmpty })

        // A reset re-primes exactly like a fresh encoder, which the bridge's timestamps assume: the
        // same input after a reset yields the same number of packets.
        encoder.reset()
        var again1 = try encoder.encode(planes: planes.map { UnsafePointer($0) }, frameCount: frames)
        again1 += try encoder.flush()
        #expect(again1.count == packets.count)

        // With DRC off the encoder holds nothing beyond its priming, so output starts within the
        // first few packets' worth of input rather than after a second and a half.
        encoder.reset()
        let again = try encoder.encode(planes: planes.map { UnsafePointer($0) }, frameCount: 8192)
        #expect(again.count >= 4)
        #expect(again.first?.isSync == true)
    }

    @Test("the muxer installs an override, forwards an init without one untouched, and survives one with no sound track")
    func muxerInstallsOverride() {
        let entry = APACSampleEntry.sampleEntry(magicCookie: Data(box("dapa", [1, 2, 3, 4])), sampleRate: 48_000)
        let videoOnly = Data(box("ftyp", Array("iso5".utf8) + [0, 0, 0, 1])
            + box("moov", box("trak", box("mdia", box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("vide".utf8) + [0])))))
        #expect(MP4SegmentMuxer.installingSoundSampleEntry(nil, in: videoOnly) == videoOnly)
        #expect(MP4SegmentMuxer.installingSoundSampleEntry(entry, in: videoOnly) == videoOnly)
    }
}
