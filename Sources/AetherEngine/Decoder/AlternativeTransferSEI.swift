import Foundation
import AetherLibavcodec
import AetherLibavutil

/// AE#839: the `alternative_transfer_characteristics` SEI (payloadType 147, H.264 and HEVC alike).
///
/// Broadcast HLG (BBC iPlayer, UK DVB-T2 UHD) keeps a backward-compatible VUI transfer, BT.2020 10-bit
/// or BT.709, so an SDR set still shows a picture, and names HLG only in this SEI. libavcodec's HEVC
/// decoder applies it to each decoded frame, but nothing applies it to the stream's `codecpar`, and that
/// is the value format detection, the display criteria, the route's `VIDEO-RANGE` and the muxer's `colr`
/// all read. Pure and stateless; malformed input returns nil.
enum AlternativeTransferSEI {

    static let payloadType = 147

    /// HLG in the ITU-T H.273 numbering `preferred_transfer_characteristics` uses (= `AVCOL_TRC_ARIB_STD_B67`).
    static let hlgTransfer: UInt8 = 18

    /// The declared stream an HLG source would ship for backward compatibility, and the only one worth
    /// reading packets for: HEVC or H.264, BT.2020 primaries (HLG has no other gamut), and a transfer that
    /// is either a gamma curve an SDR set understands or no answer at all. A PQ or HLG declaration
    /// already says what it is.
    static func declaredTransferMayHideHLG(
        codecID: AVCodecID,
        primaries: AVColorPrimaries,
        transfer: AVColorTransferCharacteristic
    ) -> Bool {
        guard codecID == AV_CODEC_ID_HEVC || codecID == AV_CODEC_ID_H264,
              primaries == AVCOL_PRI_BT2020 else { return false }
        switch transfer {
        case AVCOL_TRC_BT709, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12, AVCOL_TRC_UNSPECIFIED:
            return true
        default:
            return false
        }
    }

    /// `preferred_transfer_characteristics` of the first alternative-transfer SEI in the packet, or nil.
    static func preferredTransfer(
        in data: UnsafePointer<UInt8>, size: Int,
        codec: A53SEIParser.CodecKind, framing: A53SEIParser.NALFraming
    ) -> UInt8? {
        var preferred: UInt8?
        A53SEIParser.forEachSEIRBSP(data, size, codec: codec, framing: framing) { rbsp in
            A53SEIParser.forEachSEIPayload(rbsp) { type, offset, payloadSize in
                guard type == payloadType, payloadSize >= 1 else { return false }
                preferred = rbsp[offset]
                return true
            }
            return preferred != nil
        }
        return preferred
    }
}
