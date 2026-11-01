import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

extension AetherEngine {
    public nonisolated static let defaultPreparationDuration: Double = 4
    public nonisolated static let defaultPreparationPreroll: Double = 2

    /// Opens, positions and reads a bounded compressed A/V window without playback or decoding.
    /// The caller's custom reader may cache the physical reads. No bytes or demux state survive here.
    /// Blocks the calling thread; cancellation must be wired to the supplied one-shot token.
    ///
    /// `presentationTime` is zero-based VOD time, not an absolute container timestamp. The window
    /// starts at `max(0, presentationTime - preroll)` and ends at `presentationTime + duration`.
    /// Disc titles use the same folded timeline and EP/DVD seek machinery as playback.
    /// `audioSourceStreamIndex` names a container audio stream. Nil uses this decoder-denied probe's
    /// default, which may differ from full playback probing even without language/rendering preferences.
    /// Matching playback requires its intended explicit index for the same source and selected title.
    /// Custom reader ownership, cancellation cooperation and budget accounting match `probe(source:)`.
    /// Budget stops return incomplete evidence. Cancellation and source failures throw.
    public nonisolated static func prepareSource(
        source: MediaSource,
        presentationTime: Double,
        duration: Double = defaultPreparationDuration,
        preroll: Double = defaultPreparationPreroll,
        audioSourceStreamIndex: Int32? = nil,
        discTitleID: Int? = nil,
        limits: ProbeLimits,
        cancellation: ProbeCancellation? = nil
    ) throws -> SourcePreparationReport {
        guard presentationTime.isFinite, presentationTime >= 0,
              duration.isFinite, duration >= 0, preroll.isFinite, preroll >= 0,
              (presentationTime + duration).isFinite,
              audioSourceStreamIndex.map({ $0 >= 0 }) ?? true,
              discTitleID.map({ $0 >= 0 }) ?? true else {
            throw SourcePreparationError.invalidRequest
        }
        guard case .custom(let reader, let formatHint) = source else {
            throw SourcePreparationError.customSourceRequired
        }
        let control = try ProbeControl(limits: limits, cancellation: cancellation)
        let demuxer = Demuxer()
        demuxer.probeControl = control
        defer {
            demuxer.close()
            control.finish()
        }
        var report = SourcePreparationReport(
            outcome: .endOfSource, requestedPresentationTime: presentationTime,
            requestedPresentationRange: max(0, presentationTime - preroll)...(presentationTime + duration))
        var video: SourcePreparationProgress?
        var audio: SourcePreparationProgress?
        do {
            try control.check()
            try demuxer.open(reader: ProbeIOReader(reader: reader, control: control),
                             formatHint: formatHint, profile: preparationOpenProfile(limits: limits),
                             selectTitleID: discTitleID)
            try control.check()
            if let discTitleID {
                guard demuxer.selectedDiscTitleID == discTitleID else {
                    throw SourcePreparationError.invalidDiscTitle
                }
            }
            report.selectedDiscTitleID = demuxer.selectedDiscTitleID
            let videoIndex = demuxer.videoStreamIndex
            let audioIndex = audioSourceStreamIndex
                ?? (demuxer.audioStreamIndex >= 0 ? demuxer.audioStreamIndex : demuxer.firstAudioStreamIndexByType)
            if let audioSourceStreamIndex {
                guard let stream = demuxer.stream(at: audioSourceStreamIndex),
                      stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
                    throw SourcePreparationError.invalidAudioStream
                }
            }
            guard videoIndex >= 0 || audioIndex >= 0 else { throw SourcePreparationError.noMediaStreams }

            // A disc's published zero is its first video random-access PTS. Reading it also seeds
            // the demuxer's observed clip-0 base before a seek into another clip.
            var headVideoTime: Double?
            if demuxer.isDiscSource, videoIndex >= 0, let stream = demuxer.stream(at: videoIndex) {
                let tb = stream.pointee.time_base
                try demuxer.peekPackets(maxPackets: limits.maxPackets) { packet in
                    do { try control.checkPacketSize(packet) } catch { return true }
                    guard packet.pointee.stream_index == videoIndex, packet.pointee.pts != Int64.min,
                          tb.num > 0, tb.den > 0, preparationRandomAccess(packet, stream: stream) else { return false }
                    headVideoTime = Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
                    return true
                }
                try control.check()
            }
            let origin = preparationOrigin(demuxer: demuxer, headVideoTime: headVideoTime)
            let lower = PresentationAxis.source(displayTime: report.requestedPresentationRange.lowerBound, origin: origin)
            let upper = PresentationAxis.source(displayTime: report.requestedPresentationRange.upperBound, origin: origin)
            guard lower.isFinite, upper.isFinite,
                  Demuxer.ticks(forSeconds: upper, timeBase: AVRational(num: 1, den: AV_TIME_BASE)) != nil else {
                throw SourcePreparationError.invalidRequest
            }
            report.sourceOrigin = origin
            report.requestedSourceRange = lower...upper
            func tickSeconds(_ index: Int32) -> Double {
                guard let tb = demuxer.stream(at: index)?.pointee.time_base, tb.num > 0, tb.den > 0 else { return 0 }
                return Double(tb.num) / Double(tb.den)
            }
            if videoIndex >= 0 {
                video = SourcePreparationProgress(index: videoIndex, isVideo: true, requestedRange: lower...upper,
                                                  timestampTolerance: tickSeconds(videoIndex))
            }
            if audioIndex >= 0 {
                let audioStart = PresentationAxis.source(displayTime: presentationTime, origin: origin)
                audio = SourcePreparationProgress(index: audioIndex, isVideo: false, requestedRange: audioStart...upper,
                                                  timestampTolerance: tickSeconds(audioIndex))
            }
            let isDVD = demuxer.discTitles.first { $0.id == report.selectedDiscTitleID }?.dvdVTSN != nil
            var seekRecovery = SourcePreparationDVDSeekRecovery(
                isDVD: isDVD && report.requestedPresentationRange.lowerBound > 0,
                sourceOrigin: origin, requestedStart: lower, timestampTolerance: tickSeconds(videoIndex))

            // At the head, retain the packets stream analysis already queued, including audio priming.
            // A resume always goes through the demuxer, never a disc table's logical byte offsets.
            if report.requestedPresentationRange.lowerBound > 0 {
                let anchor = videoIndex >= 0 ? videoIndex : audioIndex
                let sought = demuxer.seekBounded(to: lower, anchorStreamIndex: anchor,
                                                timeout: control.remainingTime ?? 0, atOrBefore: true)
                try control.check()
                if !sought { report.outcome = .seekFailed }
            }
            if report.outcome != .seekFailed {
                while true {
                    try control.check()
                    guard let packet = try demuxer.readPacket() else { break }
                    var owned: UnsafeMutablePointer<AVPacket>? = packet
                    defer { trackedPacketFree(&owned) }
                    // The disc layer may have joined several individually bounded packets.
                    try control.checkPacketSize(packet)
                    let index = packet.pointee.stream_index
                    guard index == videoIndex || index == audioIndex,
                          let stream = demuxer.stream(at: index) else { continue }
                    let tb = stream.pointee.time_base
                    func seconds(_ ticks: Int64) -> Double? {
                        guard ticks != Int64.min, tb.num > 0, tb.den > 0 else { return nil }
                        let value = Double(ticks) * Double(tb.num) / Double(tb.den)
                        return value.isFinite ? value : nil
                    }
                    let pts = seconds(packet.pointee.pts)
                    let dts = seconds(packet.pointee.dts)
                    let packetDuration = max(0, seconds(packet.pointee.duration) ?? 0)
                    if index == videoIndex {
                        let randomAccess = preparationRandomAccess(packet, stream: stream)
                        if randomAccess, let keyframePTS = pts, video?.stream.randomAccessSourceTime == nil,
                           let earlier = seekRecovery.earlierAnchor(afterFirstRandomAccess: keyframePTS) {
                            // Never combine a late landing's audio or timestamp envelope with the retry.
                            video?.resetEvidence()
                            audio?.resetEvidence()
                            try control.check()
                            EngineLog.emit(
                                "[SourcePreparationSeekRecovery] requestedStart=\(lower) "
                                + "firstKeyframe=\(keyframePTS) retrySource=\(earlier)", category: .demux)
                            let sought = demuxer.seekBounded(
                                to: earlier, anchorStreamIndex: videoIndex,
                                timeout: control.remainingTime ?? 0, atOrBefore: true)
                            try control.check()
                            if !sought {
                                report.outcome = .seekFailed
                                break
                            }
                            continue
                        }
                        video?.record(pts: pts, dts: dts, duration: packetDuration,
                                      bytes: Int(packet.pointee.size), randomAccess: randomAccess)
                    } else {
                        audio?.record(pts: pts, dts: dts, duration: packetDuration,
                                      bytes: Int(packet.pointee.size), randomAccess: false)
                    }
                    if (video?.isComplete ?? true) && (audio?.isComplete ?? true) {
                        report.outcome = .complete
                        break
                    }
                }
            }
            demuxer.close()
            try control.complete()
        } catch {
            // The input seam retains the original typed stop when FFmpeg reports only EOF or EIO.
            var failure: any Error = error
            do { try control.check() } catch { failure = error }
            guard let budget = failure as? ProbeError, budget.isPreparationBudget else { throw failure }
            demuxer.close()
            try control.completeBudgetReport()
            report.outcome = .budgetExhausted(budget)
        }
        report.video = video?.stream
        report.audio = audio?.stream
        let usage = control.usage
        report.inputBytesRead = usage.inputBytes
        report.demuxedPackets = usage.packets
        if let video { EngineLog.emit("[SourcePreparationCoverage] \(video.diagnosticSummary)", category: .demux) }
        if let audio { EngineLog.emit("[SourcePreparationCoverage] \(audio.diagnosticSummary)", category: .demux) }
        return report
    }

    nonisolated static func preparationOpenProfile(limits: ProbeLimits) -> DemuxerOpenProfile {
        // Decoder-denied tracks can never satisfy find_stream_info's full-metadata exit. Giving
        // them the playback probe consumed a real ISO's entire 28 MiB allowance before one packet.
        // Keep parser analysis (not skipStreamInfo) for time bases, origin and reorder information,
        // but reserve the remaining allowance for bounded disc-tail and requested-window reads.
        var profile = probeOpenProfile(limits: limits)
        profile.probesize = min(profile.probesize, DemuxerOpenProfile.stillExtraction.probesize)
        profile.maxAnalyzeDuration = min(
            profile.maxAnalyzeDuration, DemuxerOpenProfile.stillExtraction.maxAnalyzeDuration)
        profile.allowsProbeDecoding = false
        profile.durationEstimatePolicy = .declaredDiscOnly
        return profile
    }

    nonisolated static func preparationOrigin(demuxer: Demuxer, headVideoTime: Double? = nil) -> Double {
        let formatStart = demuxer.formatStartTime
        let containerOrigin = formatStart == Int64.min ? 0 : max(0, Double(formatStart) / Double(AV_TIME_BASE))
        return PresentationOriginPolicy.origin(
            latched: containerOrigin, publishedShift: headVideoTime ?? demuxer.resolvedSourceStartOrigin,
            isLive: false, isDisc: demuxer.isDiscSource)
    }

    /// Do not treat a Matroska cue's KEYFRAME assertion as a compressed random-access witness.
    nonisolated static func preparationRandomAccess(
        _ packet: UnsafeMutablePointer<AVPacket>, stream: UnsafeMutablePointer<AVStream>
    ) -> Bool {
        guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
              let bytes = packet.pointee.data, packet.pointee.size > 0 else { return false }
        let par = stream.pointee.codecpar.pointee
        guard par.codec_id == AV_CODEC_ID_H264 || par.codec_id == AV_CODEC_ID_HEVC else {
            return true
        }
        let codec: A53SEIParser.CodecKind = par.codec_id == AV_CODEC_ID_H264 ? .h264 : .hevc
        let framing = A53SEIParser.nalFraming(codec: codec, extradata: par.extradata,
                                            size: Int(par.extradata_size))
        if case .lengthPrefixed(let size) = framing,
           !NALUnitChain.walksExactly(UnsafeRawBufferPointer(start: bytes, count: Int(packet.pointee.size)),
                                     lengthPrefixSize: size) {
            return false
        }
        if par.codec_id == AV_CODEC_ID_H264, framing == .annexB {
            return H264SPS.isRandomAccessEntry(
                fromAnnexB: UnsafeBufferPointer(start: bytes, count: Int(packet.pointee.size)))
        }
        var independent = false
        A53SEIParser.forEachNAL(bytes, Int(packet.pointee.size), framing) { nal, size in
            guard size > 0, nal[0] & 0x80 == 0 else { return }
            if par.codec_id == AV_CODEC_ID_H264 {
                if nal[0] & 31 == 5 { independent = true }
            } else if size >= 2, nal[1] & 7 != 0, (16...21).contains((nal[0] >> 1) & 63) {
                independent = true
            }
        }
        return independent
    }
}
