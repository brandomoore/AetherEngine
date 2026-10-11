import Foundation
import AetherLibavcodec
import Testing
@testable import AetherEngine

/// #699: the #409 defect on HEVC. The reporting asset (a CUVA HDR Vivid conformance stream, 4K50 Main
/// 10) carries B pictures and no `ctts`, so every sample reports `PTS == DTS` and the picture was
/// presented in decode order. Its mini-GOP is five pictures at a reorder delay of 2, which is also what
/// the twin below encodes: the next anchor is decoded four pictures ahead of the last one displayed.
@Suite("HEVC missing composition offsets (#699)")
struct HEVCCompositionOffsetRepairTests {

    /// The reporting asset's head, read with libavcodec's HEVC parser: picture order 0, 5, 3, 1, 2, 4,
    /// then the same mini-GOP again, and the third anchor at 15 while 11 to 14 are still to come.
    private func reportedSamples() -> [H264CompositionOffsetRepair.Sample] {
        let pocs: [Int64] = [0, 5, 3, 1, 2, 4, 10, 8, 6, 7, 9, 15]
        return pocs.enumerated().map { index, poc in
            H264CompositionOffsetRepair.Sample(
                dts: Int64(index - 2) * 24000,
                pts: Int64(index - 2) * 24000,
                pictureOrderCount: poc,
                isKeyframe: index == 0
            )
        }
    }

    @Test("a mini-GOP longer than the reorder delay is repaired, not refused at its ragged edge")
    func longMiniGOPIsRepaired() {
        let verdict = H264CompositionOffsetRepair.classify(
            samples: reportedSamples(), videoDelay: 2, streamStartTime: 0, ladderStart: -48000)
        #expect(verdict == .repair(.init(step: 24000, decodeLead: 48000, shift: 48000, pocStep: 1)))
    }

    @Test("the contiguous prefix has to be at least the minimum sample long")
    func contiguousPrefixNeedsTheMinimum() {
        #expect(H264CompositionOffsetRepair.hasContiguousPrefix([0, 5, 3, 1, 2, 4, 10, 8, 6, 7, 9, 15]))
        // Closes at 6 pictures only, and the next mini-GOP never closes inside the window.
        #expect(!H264CompositionOffsetRepair.hasContiguousPrefix([0, 5, 3, 1, 2, 4, 12, 9, 7, 6, 8, 11]))
        // A stray rank spread over twice the ladder never fills its range.
        #expect(!H264CompositionOffsetRepair.hasContiguousPrefix([0, 10, 6, 2, 4, 8, 20, 16, 12, 14, 18, 30]))
    }

    // MARK: - end to end, against the twin

    private struct Timestamps: Equatable, CustomStringConvertible {
        var pts: Int64
        var dts: Int64
        var description: String { "pts=\(pts) dts=\(dts)" }
    }

    private static func videoTimestamps(base64: String) throws -> [Timestamps] {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        var result: [Timestamps] = []
        while let packet = try? demuxer.readPacket() {
            if packet.pointee.stream_index == videoIndex {
                result.append(Timestamps(pts: packet.pointee.pts, dts: packet.pointee.dts))
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
        }
        return result
    }

    @Test("the repaired HEVC twin carries the healthy twin's timestamps, packet for packet")
    func repairedTwinMatchesHealthyTwin() throws {
        let healthy = try Self.videoTimestamps(base64: Self.healthyFixtureBase64)
        let repaired = try Self.videoTimestamps(base64: Self.missingFixtureBase64)
        #expect(healthy.count == 30)
        #expect(healthy.first == Timestamps(pts: 0, dts: -512))
        #expect(repaired == healthy)
    }

    @Test("the healthy HEVC twin is delivered exactly as the container wrote it")
    func healthyTwinIsUntouched() throws {
        let healthy = try Self.videoTimestamps(base64: Self.healthyFixtureBase64)
        #expect(healthy.contains { $0.pts != $0.dts })
        #expect(zip(healthy, healthy.dropFirst()).allSatisfy { $1.dts - $0.dts == 256 })
    }

    /// 64x64 HEVC Main 10, 50 fps, 30 frames, four B pictures per hierarchical mini-GOP.
    ///
    ///     ffmpeg -f lavfi -i 'testsrc=s=64x64:r=50:d=0.6' -frames:v 30 -c:v libx265 -preset ultrafast \
    ///       -pix_fmt yuv420p10le -x265-params \
    ///       'bframes=4:b-pyramid=1:b-adapt=0:keyint=30:min-keyint=30:scenecut=0' \
    ///       -tag:v hvc1 -movflags +faststart healthy.mp4
    ///     ffmpeg -i healthy.mp4 -map 0:v:0 -c:v copy -bsf:v 'setts=pts=DTS' \
    ///       -movflags +faststart missing.mp4
    private static let healthyFixtureBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAADf5tb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAACWAABAAABAAAAAAAA
        AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAANKHRy
        YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAACWAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
        AAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAlgAAAIAAAEAAAAADKBtZGlhAAAAIG1kaGQAAAAA
        AAAAAAAAAAAAADIAAAAeAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAxLbWluZgAA
        ABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAMC3N0YmwAAAoZc3RzZAAAAAAA
        AAABAAAKCWh2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEVTGF2YzYyLjI4LjEwMSBsaWJ4MjY1
        AAAAAAAAAAAAAAAY//8AAAmFaHZjQwECIAAAAJAAAAAAAB7wAPz9+voAAA8EoAABABhAAQwB//8CIAAAAwCQAAADAAADAB6VmAmh
        AAEAKkIBAQIgAAADAJAAAAMAAAMAHqAggQTZZWZKTC8BaAgAAAMACAAAAwGQQKIAAQAGRAHAc8CJJwABCQpOAQX///////////8F
        LKLeCbUXR9u7VaT+f8L8TngyNjUgKGJ1aWxkIDIxNikgLSA0LjIrMS1lNDQ0NzQ0OltNYWMgT1MgWF1bY2xhbmcgMjEuMC4wXVs2
        NCBiaXRdIDEwYml0IC0gSC4yNjUvSEVWQyBjb2RlYyAtIENvcHlyaWdodCAyMDEzLTIwMTggKGMpIE11bHRpY29yZXdhcmUsIElu
        YyAtIGh0dHA6Ly94MjY1Lm9yZyAtIG9wdGlvbnM6IGNwdWlkPTM0IGZyYW1lLXRocmVhZHM9MSBuby13cHAgbm8tcG1vZGUgbm8t
        cG1lIG5vLXBzbnIgbm8tc3NpbSBsb2ctbGV2ZWw9MCBiaXRkZXB0aD0xMCBpbnB1dC1jc3A9MSBmcHM9NTAvMSBpbnB1dC1yZXM9
        NjR4NjQgaW50ZXJsYWNlPTAgdG90YWwtZnJhbWVzPTAgbGV2ZWwtaWRjPTAgaGlnaC10aWVyPTEgdWhkLWJkPTAgcmVmPTEgbm8t
        YWxsb3ctbm9uLWNvbmZvcm1hbmNlIG5vLXJlcGVhdC1oZWFkZXJzIGFubmV4YiBuby1hdWQgbm8tZW9iIG5vLWVvcyBuby1ocmQg
        aW5mbyBoYXNoPTAgdGVtcG9yYWwtbGF5ZXJzPTAgb3Blbi1nb3AgbWluLWtleWludD0zMCBrZXlpbnQ9MzAgZ29wLWxvb2thaGVh
        ZD0wIGJmcmFtZXM9NCBiLWFkYXB0PTAgYi1weXJhbWlkIGJmcmFtZS1iaWFzPTAgcmMtbG9va2FoZWFkPTUgbG9va2FoZWFkLXNs
        aWNlcz0wIHNjZW5lY3V0PTAgbm8taGlzdC1zY2VuZWN1dCByYWRsPTAgbm8tc3BsaWNlIG5vLWludHJhLXJlZnJlc2ggY3R1PTMy
        IG1pbi1jdS1zaXplPTE2IG5vLXJlY3Qgbm8tYW1wIG1heC10dS1zaXplPTMyIHR1LWludGVyLWRlcHRoPTEgdHUtaW50cmEtZGVw
        dGg9MSBsaW1pdC10dT0wIHJkb3EtbGV2ZWw9MCBkeW5hbWljLXJkPTAuMDAgbm8tc3NpbS1yZCBuby1zaWduaGlkZSBuby10c2tp
        cCBuci1pbnRyYT0wIG5yLWludGVyPTAgbm8tY29uc3RyYWluZWQtaW50cmEgc3Ryb25nLWludHJhLXNtb290aGluZyBtYXgtbWVy
        Z2U9MiBsaW1pdC1yZWZzPTAgbm8tbGltaXQtbW9kZXMgbWU9MCBzdWJtZT0wIG1lcmFuZ2U9NTcgdGVtcG9yYWwtbXZwIG5vLWZy
        YW1lLWR1cCBuby1obWUgbm8td2VpZ2h0cCBuby13ZWlnaHRiIG5vLWFuYWx5emUtc3JjLXBpY3MgZGVibG9jaz0wOjAgbm8tc2Fv
        IG5vLXNhby1ub24tZGVibG9jayByZD0yIHNlbGVjdGl2ZS1zYW89MCBlYXJseS1za2lwIHJza2lwIGZhc3QtaW50cmEgbm8tdHNr
        aXAtZmFzdCBuby1jdS1sb3NzbGVzcyBuby1iLWludHJhIG5vLXNwbGl0cmQtc2tpcCByZHBlbmFsdHk9MCBwc3ktcmQ9Mi4wMCBw
        c3ktcmRvcT0wLjAwIG5vLXJkLXJlZmluZSBuby1sb3NzbGVzcyBjYnFwb2Zmcz0wIGNycXBvZmZzPTAgcmM9Y3JmIGNyZj0yOC4w
        IHFjb21wPTAuNjAgcXBzdGVwPTQgc3RhdHMtd3JpdGU9MCBzdGF0cy1yZWFkPTAgaXByYXRpbz0xLjQwIHBicmF0aW89MS4zMCBh
        cS1tb2RlPTEgYXEtc3RyZW5ndGg9MC4wMCBjdXRyZWUgem9uZS1jb3VudD0wIG5vLXN0cmljdC1jYnIgcWctc2l6ZT0zMiBuby1y
        Yy1ncmFpbiBxcG1heD02OSBxcG1pbj0wIG5vLWNvbnN0LXZidiBzYXI9MSBvdmVyc2Nhbj0wIHZpZGVvZm9ybWF0PTUgcmFuZ2U9
        MCBjb2xvcnByaW09MiB0cmFuc2Zlcj0yIGNvbG9ybWF0cml4PTIgY2hyb21hbG9jPTAgZGlzcGxheS13aW5kb3c9MCBjbGw9MCww
        IG1pbi1sdW1hPTAgbWF4LWx1bWE9MTAyMyBsb2cyLW1heC1wb2MtbHNiPTggdnVpLXRpbWluZy1pbmZvIHZ1aS1ocmQtaW5mbyBz
        bGljZXM9MSBuby1vcHQtcXAtcHBzIG5vLW9wdC1yZWYtbGlzdC1sZW5ndGgtcHBzIG5vLW11bHRpLXBhc3Mtb3B0LXJwcyBzY2Vu
        ZWN1dC1iaWFzPTAuMDUgbm8tb3B0LWN1LWRlbHRhLXFwIG5vLWFxLW1vdGlvbiBuby1oZHIxMCBuby1oZHIxMC1vcHQgbm8tZGhk
        cjEwLW9wdCBuby1pZHItcmVjb3Zlcnktc2VpIGFuYWx5c2lzLXJldXNlLWxldmVsPTAgYW5hbHlzaXMtc2F2ZS1yZXVzZS1sZXZl
        bD0wIGFuYWx5c2lzLWxvYWQtcmV1c2UtbGV2ZWw9MCBzY2FsZS1mYWN0b3I9MCByZWZpbmUtaW50cmE9MCByZWZpbmUtaW50ZXI9
        MCByZWZpbmUtbXY9MSByZWZpbmUtY3R1LWRpc3RvcnRpb249MCBuby1saW1pdC1zYW8gY3R1LWluZm89MCBuby1sb3dwYXNzLWRj
        dCByZWZpbmUtYW5hbHlzaXMtdHlwZT0wIGNvcHktcGljPTEgbWF4LWF1c2l6ZS1mYWN0b3I9MS4wIG5vLWR5bmFtaWMtcmVmaW5l
        IG5vLXNpbmdsZS1zZWkgbm8taGV2Yy1hcSBuby1zdnQgbm8tZmllbGQgcXAtYWRhcHRhdGlvbi1yYW5nZT0xLjAwIHNjZW5lY3V0
        LWF3YXJlLXFwPTBjb25mb3JtYW5jZS13aW5kb3ctb2Zmc2V0cyByaWdodD0wIGJvdHRvbT0wIGRlY29kZXItbWF4LXJhdGU9MCBu
        by12YnYtbGl2ZS1tdWx0aS1wYXNzIG5vLW1jc3RmIG5vLXNicmMgbm8tZnJhbWUtcmOAAAAACmZpZWwBAAAAABBwYXNwAAAAAQAA
        AAEAAAAUYnRydAAAAAAAAFZoAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAeAAABAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAKnNkdHAA
        AAAAIBAQGBgYEBAYGBgQEBgYGBAQGBgYEBAYGBgQEBgYAAAA2GN0dHMAAAAAAAAAGQAAAAEAAAIAAAAAAQAABgAAAAABAAADAAAA
        AAIAAAAAAAAAAQAAAQAAAAABAAAGAAAAAAEAAAMAAAAAAgAAAAAAAAABAAABAAAAAAEAAAYAAAAAAQAAAwAAAAACAAAAAAAAAAEA
        AAEAAAAAAQAABgAAAAABAAADAAAAAAIAAAAAAAAAAQAAAQAAAAABAAAGAAAAAAEAAAMAAAAAAgAAAAAAAAABAAABAAAAAAEAAAUA
        AAAAAQAAAgAAAAABAAAAAAAAAAEAAAEAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAeAAAAAQAAAIxzdHN6AAAAAAAAAAAAAAAeAAAE
        FQAAABUAAAAOAAAADwAAAA8AAAAOAAAALAAAAA8AAAAQAAAAEAAAAA8AAAAsAAAAEAAAABAAAAAQAAAADwAAADoAAAAQAAAAEAAA
        ABAAAAAPAAAALgAAABAAAAAQAAAAEAAAAA8AAAAuAAAAEAAAAA8AAAAPAAAAFHN0Y28AAAAAAAAAAQAADioAAABidWR0YQAAAFpt
        ZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAAAAEAAAAATGF2
        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
        """

    private static let missingFixtureBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAADSZtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAACMAABAAABAAAAAAAA
        AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAMUHRy
        YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAACMAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA
        AAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAjAAAAIAAAEAAAAAC8htZGlhAAAAIG1kaGQAAAAA
        AAAAAAAAAAAAADIAAAAeAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAtzbWluZgAA
        ABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAALM3N0YmwAAAoZc3RzZAAAAAAA
        AAABAAAKCWh2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEVTGF2YzYyLjI4LjEwMSBsaWJ4MjY1
        AAAAAAAAAAAAAAAY//8AAAmFaHZjQwECIAAAAJAAAAAAAB7wAPz9+voAAA8EoAABABhAAQwB//8CIAAAAwCQAAADAAADAB6VmAmh
        AAEAKkIBAQIgAAADAJAAAAMAAAMAHqAggQTZZWZKTC8BaAgAAAMACAAAAwGQQKIAAQAGRAHAc8CJJwABCQpOAQX///////////8F
        LKLeCbUXR9u7VaT+f8L8TngyNjUgKGJ1aWxkIDIxNikgLSA0LjIrMS1lNDQ0NzQ0OltNYWMgT1MgWF1bY2xhbmcgMjEuMC4wXVs2
        NCBiaXRdIDEwYml0IC0gSC4yNjUvSEVWQyBjb2RlYyAtIENvcHlyaWdodCAyMDEzLTIwMTggKGMpIE11bHRpY29yZXdhcmUsIElu
        YyAtIGh0dHA6Ly94MjY1Lm9yZyAtIG9wdGlvbnM6IGNwdWlkPTM0IGZyYW1lLXRocmVhZHM9MSBuby13cHAgbm8tcG1vZGUgbm8t
        cG1lIG5vLXBzbnIgbm8tc3NpbSBsb2ctbGV2ZWw9MCBiaXRkZXB0aD0xMCBpbnB1dC1jc3A9MSBmcHM9NTAvMSBpbnB1dC1yZXM9
        NjR4NjQgaW50ZXJsYWNlPTAgdG90YWwtZnJhbWVzPTAgbGV2ZWwtaWRjPTAgaGlnaC10aWVyPTEgdWhkLWJkPTAgcmVmPTEgbm8t
        YWxsb3ctbm9uLWNvbmZvcm1hbmNlIG5vLXJlcGVhdC1oZWFkZXJzIGFubmV4YiBuby1hdWQgbm8tZW9iIG5vLWVvcyBuby1ocmQg
        aW5mbyBoYXNoPTAgdGVtcG9yYWwtbGF5ZXJzPTAgb3Blbi1nb3AgbWluLWtleWludD0zMCBrZXlpbnQ9MzAgZ29wLWxvb2thaGVh
        ZD0wIGJmcmFtZXM9NCBiLWFkYXB0PTAgYi1weXJhbWlkIGJmcmFtZS1iaWFzPTAgcmMtbG9va2FoZWFkPTUgbG9va2FoZWFkLXNs
        aWNlcz0wIHNjZW5lY3V0PTAgbm8taGlzdC1zY2VuZWN1dCByYWRsPTAgbm8tc3BsaWNlIG5vLWludHJhLXJlZnJlc2ggY3R1PTMy
        IG1pbi1jdS1zaXplPTE2IG5vLXJlY3Qgbm8tYW1wIG1heC10dS1zaXplPTMyIHR1LWludGVyLWRlcHRoPTEgdHUtaW50cmEtZGVw
        dGg9MSBsaW1pdC10dT0wIHJkb3EtbGV2ZWw9MCBkeW5hbWljLXJkPTAuMDAgbm8tc3NpbS1yZCBuby1zaWduaGlkZSBuby10c2tp
        cCBuci1pbnRyYT0wIG5yLWludGVyPTAgbm8tY29uc3RyYWluZWQtaW50cmEgc3Ryb25nLWludHJhLXNtb290aGluZyBtYXgtbWVy
        Z2U9MiBsaW1pdC1yZWZzPTAgbm8tbGltaXQtbW9kZXMgbWU9MCBzdWJtZT0wIG1lcmFuZ2U9NTcgdGVtcG9yYWwtbXZwIG5vLWZy
        YW1lLWR1cCBuby1obWUgbm8td2VpZ2h0cCBuby13ZWlnaHRiIG5vLWFuYWx5emUtc3JjLXBpY3MgZGVibG9jaz0wOjAgbm8tc2Fv
        IG5vLXNhby1ub24tZGVibG9jayByZD0yIHNlbGVjdGl2ZS1zYW89MCBlYXJseS1za2lwIHJza2lwIGZhc3QtaW50cmEgbm8tdHNr
        aXAtZmFzdCBuby1jdS1sb3NzbGVzcyBuby1iLWludHJhIG5vLXNwbGl0cmQtc2tpcCByZHBlbmFsdHk9MCBwc3ktcmQ9Mi4wMCBw
        c3ktcmRvcT0wLjAwIG5vLXJkLXJlZmluZSBuby1sb3NzbGVzcyBjYnFwb2Zmcz0wIGNycXBvZmZzPTAgcmM9Y3JmIGNyZj0yOC4w
        IHFjb21wPTAuNjAgcXBzdGVwPTQgc3RhdHMtd3JpdGU9MCBzdGF0cy1yZWFkPTAgaXByYXRpbz0xLjQwIHBicmF0aW89MS4zMCBh
        cS1tb2RlPTEgYXEtc3RyZW5ndGg9MC4wMCBjdXRyZWUgem9uZS1jb3VudD0wIG5vLXN0cmljdC1jYnIgcWctc2l6ZT0zMiBuby1y
        Yy1ncmFpbiBxcG1heD02OSBxcG1pbj0wIG5vLWNvbnN0LXZidiBzYXI9MSBvdmVyc2Nhbj0wIHZpZGVvZm9ybWF0PTUgcmFuZ2U9
        MCBjb2xvcnByaW09MiB0cmFuc2Zlcj0yIGNvbG9ybWF0cml4PTIgY2hyb21hbG9jPTAgZGlzcGxheS13aW5kb3c9MCBjbGw9MCww
        IG1pbi1sdW1hPTAgbWF4LWx1bWE9MTAyMyBsb2cyLW1heC1wb2MtbHNiPTggdnVpLXRpbWluZy1pbmZvIHZ1aS1ocmQtaW5mbyBz
        bGljZXM9MSBuby1vcHQtcXAtcHBzIG5vLW9wdC1yZWYtbGlzdC1sZW5ndGgtcHBzIG5vLW11bHRpLXBhc3Mtb3B0LXJwcyBzY2Vu
        ZWN1dC1iaWFzPTAuMDUgbm8tb3B0LWN1LWRlbHRhLXFwIG5vLWFxLW1vdGlvbiBuby1oZHIxMCBuby1oZHIxMC1vcHQgbm8tZGhk
        cjEwLW9wdCBuby1pZHItcmVjb3Zlcnktc2VpIGFuYWx5c2lzLXJldXNlLWxldmVsPTAgYW5hbHlzaXMtc2F2ZS1yZXVzZS1sZXZl
        bD0wIGFuYWx5c2lzLWxvYWQtcmV1c2UtbGV2ZWw9MCBzY2FsZS1mYWN0b3I9MCByZWZpbmUtaW50cmE9MCByZWZpbmUtaW50ZXI9
        MCByZWZpbmUtbXY9MSByZWZpbmUtY3R1LWRpc3RvcnRpb249MCBuby1saW1pdC1zYW8gY3R1LWluZm89MCBuby1sb3dwYXNzLWRj
        dCByZWZpbmUtYW5hbHlzaXMtdHlwZT0wIGNvcHktcGljPTEgbWF4LWF1c2l6ZS1mYWN0b3I9MS4wIG5vLWR5bmFtaWMtcmVmaW5l
        IG5vLXNpbmdsZS1zZWkgbm8taGV2Yy1hcSBuby1zdnQgbm8tZmllbGQgcXAtYWRhcHRhdGlvbi1yYW5nZT0xLjAwIHNjZW5lY3V0
        LWF3YXJlLXFwPTBjb25mb3JtYW5jZS13aW5kb3ctb2Zmc2V0cyByaWdodD0wIGJvdHRvbT0wIGRlY29kZXItbWF4LXJhdGU9MCBu
        by12YnYtbGl2ZS1tdWx0aS1wYXNzIG5vLW1jc3RmIG5vLXNicmMgbm8tZnJhbWUtcmOAAAAACmZpZWwBAAAAABBwYXNwAAAAAQAA
        AAEAAAAUYnRydAAAAAAAAFZoAABWaAAAABhzdHRzAAAAAAAAAAEAAAAeAAABAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAKnNkdHAA
        AAAAIBAQGBgYEBAYGBgQEBgYGBAQGBgYEBAYGBgQEBgYAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAeAAAAAQAAAIxzdHN6AAAAAAAA
        AAAAAAAeAAAEFQAAABUAAAAOAAAADwAAAA8AAAAOAAAALAAAAA8AAAAQAAAAEAAAAA8AAAAsAAAAEAAAABAAAAAQAAAADwAAADoA
        AAAQAAAAEAAAABAAAAAPAAAALgAAABAAAAAQAAAAEAAAAA8AAAAuAAAAEAAAAA8AAAAPAAAAFHN0Y28AAAAAAAAAAQAADVIAAABi
        dWR0YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAA
        AAEAAAAATGF2ZjYyLjEyLjEwMQAAAAhmcmVlAAAGg21kYXQAAAQRKAGsKYCoC2PeLG++3GQqYwPd5f4iYh0irT8tB7IqSXHt9aYS
        3pMd85e6qfFPLmPrzOtW5kKQFnIBbc1MydWMNZHnyNpet0rgxNXjNkPiSCdRctOJmNboZXO3x//WaYP3Aq3x+xuQhmV0stHPZdcm
        t5Jbna/QezfTDUUKoJwPS+5DmWJq9yw6gPeCyy1Rli+B4Uaxa0tsVKRIN5YnsFwCI3/P3LFhWQ1aulZViQoT/4lpsoXQXXUKsqQ1
        G/jmT98sRqYV9OoAjm8GpBUioTmj3bkTXiDhlAX6da2TWpoxFZOqcNETPTflTcnZRJjTcqAyvaoYMPHFMywXDq05X6Klw+5LUC0m
        /IRo1LpwAEX6dQqd6AMic6AKZUI9Znm7vmJQUJlPMTBWdxUiVdl5FhUt+Aukxa3ZF8pAQW5ql0lJa7DCNvwtqZKJviO6bfAN+tV0
        zaPRskCedm8M7ojLfJp4/boaEq///9trlDjx6oCNe2I8TiPY/CgD6qXDF/1Ns/Pjv2jYMkPN+buRIG1PElW37KjK5VLSI8fBS/Iw
        NmfWzMlJIfMPoQm3zMBouaAJCeUOYHTE9xl2KRPwOcs6TCcSW0VCQhefFSlomBwBIgI3UnQQz1HyVVmMr6tMSVFPe2zKSCztBKkO
        3sx/RLk88SA0dTCYwwefoazaTXOldBEPrQO1yAxZ+iqmsAslyNmichJ397ob6lWVj4HKIoH5dM3hA8rrhOqTQ5tqehE2pajPeVnr
        YlxmlH81gtpi9MT6bA16aeJ9eY2gdP3A+QLrPLMTgHsgqa3k6rkOOpyrF15SswW9JNzerZOCRpfqw5AXp6y1aKyNhsYUJsDfwWkR
        RGgWlC5zzB1jy5gOFuMIIM07Ew6eKOwU2teliFSzdk1MDHXcAwI+F3vaFsNEYJmk7zRnh873ftuThZQx28rwlmuf4+Ab8qv6amuM
        d/sC8/zxhfF0UbCQSENNgeDzCZVTj8B8T0BZUoKHPn//KdmxoyikLbd2e3sEJyR/0HOhkOZnEKzLIqflcKN10SX5bgj9Q7at1ZCO
        MhQ5AzS+F+iLb4qsLQJQeIApndqD3H7Llw14c3T0vZL1cAAsiSs5yFCuCwHYC8T8A7WdBrQM7As8BpBZgSAlXnJN7TxLfvXv3wwH
        VKsXaNTzxIiV4s0Xtyhve/TUT6JuZtAZMJ3cWxXsJluym+z1c6poBR/aMnWSyhTuqOLa/5vU443t7Y4MwVpe6gBypmgX9uCJmCBk
        me8et61FbpkZ+Mgc4AQJVenBce5b8yAQWHWd5zBk4zRu2L0VK9vuSu7ZgHYo51UxzwMQCNJQ7a92ZThKFLyDmFT5gqeltYfIjka3
        uHJDxujXGscwFPTQRj4LKfyFRuPy3xCSsS8YMYm+AAAAEQIB0ClLiBRAs1pEo6u+ZSuXAAAACgIB4GSdYIFkkngAAAALAAHgJPVe
        iQMYkPAAAAALAAHgRNdeiQMIkPAAAAAKAAHghrfggYyQ8AAAACgCAdBQktXiBRCzWkFey1+VMBHdPUlsBUhuilioNQ9hOPghYTzW
        H99wAAAACwIB4QInV1ggWZJ4AAAADAAB4Mb1VeiQMYCQ8AAAAAwAAeDm1XXokDCAkPAAAAALAAHhIi3XggYwkPAAAAAoAgHQeLLV
        1iBRs1fdRSLNr7qLgw9k6qz4+0LjUk+0NRRyL70QOwEQgAAAAAwCAeGiJ1LWCBZAkngAAAAMAAHhZvVV6JAxgJDwAAAADAAB4YbV
        deiQMICQ8AAAAAsAAeHCLdeCBjCQ8AAAADYCAdCgstXWIFGzWkXwn0I9zhHfu+OUlQywM4hhFO/Rgmzzdyv0TypArT007GQJ1LjP
        L7Vu2TAAAAAMAgHiQidS1ggWwJJ4AAAADAAB4gb1VeiQMICQ8AAAAAwAAeIm1XXokDGAkPAAAAALAAHiYi3XggYwkPAAAAAqAgHQ
        yLLV1iBTs1pF2UwP6z4eiZizCiXuyD+VkAZ8PmIohoKUP1a5rFLYAAAADAIB4uInUtYIFkCSeAAAAAwAAeKm9VXokDCAkPAAAAAM
        AAHixtV16JAxgJDwAAAACwAB4wIt14IGMJDwAAAAKgIB0OiyVdYgUbNX33n2/kixaxBTSBJOYLe+rSsDXZK4kET9EzPm7DExEgAA
        AAwCAeNiJVLWCBbAkngAAAALAAHjRvXXokDGkPAAAAALAAHjgi1XggYwkPA=
        """
}
