import Foundation

/// The `apac` sample entry, and the init-segment rewrite that installs it.
///
/// libavformat has no Apple Positional Audio Codec (its `apac` codec id is Marian's A-pac, an
/// unrelated 1990s codec), so movenc cannot write this sample entry. The spatial bridge therefore
/// hands the muxer a stand-in audio stream (ALAC, whose entry movenc builds from codec parameters
/// alone and whose packets it never inspects) and the finished `ftyp`+`moov` has its audio sample
/// entry replaced with this one. Fragments need no rewrite: `moof`/`mdat` carry sizes, durations
/// and sync flags, none of which name the codec.
///
/// Layout copied from what AVAssetWriter writes for APAC in an HLS fMP4 (macOS 27): an
/// AudioSampleEntry v0 with `channelcount` 2, `samplesize` 16 and the rate, whatever the real
/// channel count (the channel layout lives in the configuration), followed by the encoder's magic
/// cookie, which is already the complete `dapa` box.
enum APACSampleEntry {

    static func sampleEntry(magicCookie: Data, sampleRate: Int) -> Data {
        var body = Data()
        body.append(contentsOf: [0, 0, 0, 0, 0, 0])         // reserved
        body.append(contentsOf: [0, 1])                     // data_reference_index
        body.append(contentsOf: [UInt8](repeating: 0, count: 8)) // version 0, revision, vendor
        body.append(contentsOf: [0, 2])                     // channelcount
        body.append(contentsOf: [0, 16])                    // samplesize
        body.append(contentsOf: [0, 0, 0, 0])               // pre_defined, reserved
        // 16.16 fixed point: a v0 entry cannot state a rate above 65535 Hz, and the shift would
        // wrap silently. Object audio is 48 kHz only.
        precondition((1...65535).contains(sampleRate), "an AudioSampleEntry v0 holds rates up to 65535 Hz")
        let rate = UInt32(sampleRate) << 16
        body.append(contentsOf: bigEndian(rate))
        body.append(magicCookie)
        var box = Data(bigEndian(UInt32(8 + body.count)))
        box.append(contentsOf: Array("apac".utf8))
        box.append(body)
        return box
    }

    /// HLS `CODECS` value. Apple's HLS authoring spec (9.20) requires the APAC profile and level;
    /// profile 31 is multichannel, and the level is the channel-count tier from Apple's APAC
    /// specification (2, 6, 8, 12, 24, 32, 64 channels -> 0...6). AVPlayer on the tvOS 27 simulator
    /// accepts `apac.31.03` for 7.1.4 and `apac.31.04` for 9.1.6 and rejects a bare `apac`.
    static func codecsString(channelCount: Int) -> String {
        let tiers = [2, 6, 8, 12, 24, 32, 64]
        let level = tiers.firstIndex(where: { channelCount <= $0 }) ?? (tiers.count - 1)
        return String(format: "apac.31.%02d", level)
    }

    /// `initBytes` with the sound track's first sample entry replaced by `entry`, or nil when the
    /// init has no parseable sound track (the caller then forwards it unchanged, and the failure
    /// shows up as a load error naming the audio rather than as corrupt bytes).
    static func replacingSoundSampleEntry(in initBytes: Data, with entry: Data) -> Data? {
        let b = [UInt8](initBytes)
        let n = b.count

        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= n else { return nil }
            return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
        }
        func fourcc(_ o: Int) -> String? {
            guard o >= 0, o + 4 <= n else { return nil }
            return String(bytes: b[o..<o + 4], encoding: .ascii)
        }
        struct Box { let start: Int; let type: String; let payload: Int; let end: Int }
        func boxes(_ start: Int, _ end: Int) -> [Box] {
            var out: [Box] = []
            var o = start
            while o + 8 <= end {
                guard let size = u32(o), size != 1, let t = fourcc(o + 4) else { break }
                let boxSize = size == 0 ? (end - o) : Int(size)
                guard boxSize >= 8, o + boxSize <= end else { break }
                out.append(Box(start: o, type: t, payload: o + 8, end: o + boxSize))
                o += boxSize
            }
            return out
        }
        func child(_ parent: Box, _ type: String) -> Box? {
            boxes(parent.payload, parent.end).first { $0.type == type }
        }

        guard let moov = boxes(0, n).first(where: { $0.type == "moov" }) else { return nil }
        for trak in boxes(moov.payload, moov.end) where trak.type == "trak" {
            guard let mdia = child(trak, "mdia"),
                  let hdlr = child(mdia, "hdlr"),
                  fourcc(hdlr.payload + 8) == "soun",   // hdlr: version/flags(4) + pre_defined(4) + handler_type
                  let minf = child(mdia, "minf"),
                  let stbl = child(minf, "stbl"),
                  let stsd = child(stbl, "stsd")
            else { continue }
            // stsd: version/flags(4) + entry_count(4), then the entries.
            guard let first = boxes(stsd.payload + 8, stsd.end).first else { return nil }

            var out = Array(b[0..<first.start])
            out.append(contentsOf: entry)
            out.append(contentsOf: b[first.end..<n])
            let delta = entry.count - (first.end - first.start)
            // Every ancestor's header precedes the replaced entry, so its offset is the same in `out`.
            for ancestor in [stsd, stbl, minf, mdia, trak, moov] {
                let old = Int(u32(ancestor.start)!)
                // Size 0 means "to the end of the file", which stays true after the splice.
                if old == 0 { continue }
                let new = UInt32(old + delta)
                out.replaceSubrange(ancestor.start..<ancestor.start + 4, with: bigEndian(new))
            }
            return Data(out)
        }
        return nil
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}
