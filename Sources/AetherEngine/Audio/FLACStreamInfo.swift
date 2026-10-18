import AetherLibavcodec

/// The two blocksize fields of a FLAC `STREAMINFO`, read from a codecpar's extradata.
///
/// AE#764: CoreMedia keys FLAC on the `min_blocksize` FIELD, with a floor of 192 samples (FLAC's smallest
/// standard block size), well above the spec's 16. Measured on macOS 26 against fixed-blocksize encodes and
/// field-patched copies of them: a field below 192 drops the audio track (`asset.tracks` without audio, an
/// HLS item fails `-11829` / `-12848`) even when every real frame is 4608 samples; a field of 192 over real
/// 144-sample frames gets past that check and then hangs Apple's decoder (`copyNextSampleBuffer` never
/// returns). So the field can only be rewritten upward when the frames really are that large, which is the
/// AE#221 clamp's premise, and a stream whose blocks really are small has to be decoded by libavcodec.
enum FLACStreamInfo {
    /// Smallest `min_blocksize` CoreMedia accepts. 191 fails, 192 plays and decodes bit-exact.
    static let coreMediaMinimumBlockSize: UInt16 = 192
    /// Spec floor for both blocksize fields.
    static let specMinimumBlockSize: UInt16 = 16
    /// `STREAMINFO` payload length.
    static let size = 34

    /// nil for a non-FLAC codecpar or extradata too short to be a `STREAMINFO`.
    static func blockSizes(_ codecpar: UnsafePointer<AVCodecParameters>) -> (min: UInt16, max: UInt16)? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_FLAC,
              let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size >= Int32(size) else { return nil }
        return blockSizes(UnsafeBufferPointer(start: extradata, count: 4))
    }

    static func blockSizes<C: Collection>(_ bytes: C) -> (min: UInt16, max: UInt16)? where C.Element == UInt8 {
        let b = Array(bytes.prefix(4))
        guard b.count == 4 else { return nil }
        return (UInt16(b[0]) << 8 | UInt16(b[1]), UInt16(b[2]) << 8 | UInt16(b[3]))
    }

    /// AE#221: the value an illegal `min_blocksize` is clamped up to, or nil when there is nothing to repair
    /// or nothing to repair it with. `max_blocksize` is the only blocksize the container attests to.
    static func repairedMinBlockSize(min: UInt16, max: UInt16) -> UInt16? {
        guard min < specMinimumBlockSize, max >= specMinimumBlockSize else { return nil }
        return max
    }

    /// Whether CoreMedia refuses this stream as the source declares it. Audio-only playback hands AVPlayer
    /// the source itself, so nothing repairs the field on that route. False when there is no `STREAMINFO`
    /// to read, so an unreadable header keeps whatever route it had.
    static func coreMediaRejectsSource(_ codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        guard let sizes = blockSizes(codecpar) else { return false }
        return sizes.min < coreMediaMinimumBlockSize
    }

    /// Whether CoreMedia refuses the `dfLa` a stream copy would write, i.e. after the AE#221 repair.
    static func coreMediaRejectsStreamCopy(_ codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        guard let sizes = blockSizes(codecpar) else { return false }
        let written = repairedMinBlockSize(min: sizes.min, max: sizes.max) ?? sizes.min
        return written < coreMediaMinimumBlockSize
    }

    /// The samples per frame a fixed-blocksize stream declares (min = max), for a packet duration fallback.
    static func fixedBlockSize(_ codecpar: UnsafePointer<AVCodecParameters>) -> Int64? {
        guard let sizes = blockSizes(codecpar), sizes.min == sizes.max,
              sizes.max >= specMinimumBlockSize else { return nil }
        return Int64(sizes.max)
    }
}
