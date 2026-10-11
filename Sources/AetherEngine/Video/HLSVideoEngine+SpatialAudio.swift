import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension HLSVideoEngine {

    /// The bed a source should be rendered into, or nil to keep the ordinary bridge.
    ///
    /// TrueHD only, and only when FFmpeg marked the stream Atmos (`AV_PROFILE_TRUEHD_ATMOS`, which
    /// mlpdec sets from the major sync while the probe decodes a frame): a TrueHD track without an
    /// object presentation gains nothing from rendering and would lose its lossless 7.1 for it.
    /// 48 kHz, or not yet known, since TrueHD reports its rate from the first frame and Atmos is
    /// only ever authored at 48 kHz.
    static func spatialRenderingLayout(
        rendering: ObjectAudioRendering,
        codecID: AVCodecID,
        profile: Int32,
        sampleRate: Int32
    ) -> SpatialSpeakerLayout? {
        guard let layout = rendering.layout,
              codecID == AV_CODEC_ID_TRUEHD,
              profile == AV_PROFILE_TRUEHD_ATMOS,
              sampleRate == 0 || sampleRate == Int32(ObjectAudioRendering.sampleRate)
        else { return nil }
        return layout
    }

    /// Build the producer on a `SpatialAudioBridge` when the host asked for object rendering and the
    /// source qualifies. Nil means "not this route": ineligible, unsupported OS, or a bridge/header
    /// failure, each logged, and the caller carries on with the ordinary bridge cascade, so asking
    /// for Atmos never costs a session its audio.
    func buildSpatialAudioProducerIfEligible(
        audioStream: UnsafeMutablePointer<AVStream>,
        sourceAudioStreamIndex: Int32,
        sourceCodecLabel: String,
        audioHLSCodecs: inout String?,
        audioLanguage: String?
    ) -> HLSSegmentProducer? {
        let par = audioStream.pointee.codecpar.pointee
        guard let layout = Self.spatialRenderingLayout(
            rendering: objectAudioRendering, codecID: par.codec_id,
            profile: par.profile, sampleRate: par.sample_rate)
        else {
            if par.codec_id == AV_CODEC_ID_TRUEHD {
                if objectAudioRendering != .off {
                    EngineLog.emit(
                        "[HLSVideoEngine] object rendering requested but TrueHD is not 48 kHz Atmos "
                        + "(profile=\(par.profile) rate=\(par.sample_rate)); keeping the channel bridge",
                        category: .session
                    )
                } else if par.profile == AV_PROFILE_TRUEHD_ATMOS {
                    // The host's choice, not a failure, but the one a missing-heights report turns on:
                    // the channel bridge plays the 7.1 presentation, where the objects are mixed into
                    // the floor channels.
                    EngineLog.emit(
                        "[HLSVideoEngine] TrueHD Atmos with objectAudioRendering off; the channel bridge "
                        + "carries the 7.1 presentation, with the objects mixed into the floor channels",
                        category: .session
                    )
                }
            }
            return nil
        }
        // VOD only: the live reopen and splice paths re-time the bridge in ways this one's encoder
        // latency and fixed packet stamping do not follow.
        guard !isLiveSession else {
            EngineLog.emit(
                "[HLSVideoEngine] TrueHD Atmos rendering is VOD only; keeping the channel bridge on this live session",
                category: .session
            )
            return nil
        }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            EngineLog.emit(
                "[HLSVideoEngine] TrueHD Atmos rendering needs OS 26 (APAC encoder API); keeping the channel bridge",
                category: .session
            )
            return nil
        }

        let bridge: SpatialAudioBridge
        do {
            let decoder = try TrueHDObjectAudioDecoder()
            bridge = try SpatialAudioBridge(
                srcTimeBase: audioStream.pointee.time_base, layout: layout, decoder: decoder)
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] ERROR: TrueHD Atmos rendering unavailable (\(error)); keeping the channel bridge",
                category: .session
            )
            return nil
        }
        guard let cp = bridge.encoderCodecpar else {
            bridge.close()
            return nil
        }
        let cfg = HLSSegmentProducer.AudioConfig(
            codecpar: cp,
            timeBase: bridge.encoderTimeBase,
            sourceStreamIndex: sourceAudioStreamIndex,
            inputTimeBase: bridge.encoderTimeBase,
            sourceTimeBase: audioStream.pointee.time_base,
            bridge: bridge,
            language: audioLanguage
        )
        savedAudioConfig = cfg
        audioBridge = bridge
        // Same surfacing as the channel bridge: a decoder that never answers is a failure, not silence.
        if sideAudioDemuxer == nil {
            let streamIndex = sourceAudioStreamIndex
            bridge.onDecoderProducedNothing = { [weak self] stats in
                self?.handleBridgeDecodedNothing(streamIndex: streamIndex, summary: stats.summary)
            }
        }
        do {
            let producer = try makeProducer(baseIndex: initialProducerBaseIndex)
            audioHLSCodecs = bridge.hlsCodecs
            // Short on purpose: hosts append it to a track title in one-line stats rows.
            audioPipelineDescription = "\(sourceCodecLabel) Atmos → APAC \(layout.rawValue)"
            audioDelivery = .bridged
            EngineLog.emit(
                "[HLSVideoEngine] TrueHD Atmos: objects rendered into \(layout.rawValue), delivered as "
                + "\(bridge.hlsCodecs) (lossy; the lossless 7.1 channel presentation is not used)",
                category: .session
            )
            return producer
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] APAC producer header write failed (\(error)); keeping the channel bridge",
                category: .session
            )
            savedAudioConfig = nil
            audioBridge = nil
            bridge.close()
            return nil
        }
    }
}
