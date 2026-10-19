import Foundation

/// Reads whether a TrueHD stream carries Atmos from the major sync in its packets, the same test
/// FFmpeg's mlpdec applies when it sets `AV_PROFILE_TRUEHD_ATMOS`: four substreams, and the top bit
/// of `substream_info` set (the 16-channel presentation). FFmpeg only learns it by decoding a frame
/// during `find_stream_info`, so a track that starts after the probe window keeps an unknown profile.
enum TrueHDMajorSync {
    /// `format_sync` of a TrueHD (not MLP) major sync.
    static let formatSync: [UInt8] = [0xF8, 0x72, 0x6F, 0xBA]
    /// `signature` following `format_info`.
    static let signature: [UInt8] = [0xB7, 0x52]

    /// Walks the access units in one demuxed packet. True or false from the first major sync found,
    /// nil when the packet holds none (a major sync recurs at least every 128 access units).
    static func isAtmos(_ packet: UnsafeRawBufferPointer) -> Bool? {
        var offset = 0
        while offset + 4 <= packet.count {
            // Access unit header: 4 bits check nibble, 12 bits length in 16-bit words, 16 bits timing.
            let length = (Int(packet[offset] & 0x0F) << 8 | Int(packet[offset + 1])) * 2
            guard length >= 4 else { return nil }
            if offset + 22 <= packet.count,
               zip(formatSync.indices, formatSync).allSatisfy({ packet[offset + 4 + $0] == $1 }),
               packet[offset + 12] == signature[0], packet[offset + 13] == signature[1] {
                let substreams = packet[offset + 20] >> 4
                let substreamInfo = packet[offset + 21]
                return substreams == 4 && substreamInfo >> 7 == 1
            }
            offset += length
        }
        return nil
    }
}
