import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// MP4 AAC can describe a clock different from the 1024 PCM samples in each access unit.
/// AVPlayer's native AAC path does not reconcile that accumulating disagreement (Plozz#89).
enum AACSampleTimeline {
    static let maximumIndexEntries: Int32 = 1_000_000
    static let driftThresholdSamples: Int64 = 2048
    static let maximumRateCorrection = 0.05

    static func requiresCorrection(stream: UnsafeMutablePointer<AVStream>) -> Bool {
        let cp = stream.pointee.codecpar.pointee
        guard cp.codec_id == AV_CODEC_ID_AAC, cp.profile == 1, cp.frame_size == 1024,
              cp.sample_rate > 0, cp.sample_rate <= 192_000,
              stream.pointee.time_base.num > 0, stream.pointee.time_base.den > 0 else { return false }
        let count = avformat_index_get_entries_count(stream)
        guard count >= 3, count <= maximumIndexEntries,
              let first = avformat_index_get_entry(stream, 0) else { return false }
        let origin = first.pointee.timestamp
        guard origin != Int64.min else { return false }
        var previous = origin
        var needsCorrection = false
        let sampleBase = AVRational(num: 1, den: cp.sample_rate)
        let stepTolerance = Int64((1024 * maximumRateCorrection).rounded(.up))
        for index in 1..<count {
            guard let entry = avformat_index_get_entry(stream, index) else { return false }
            let timestamp = entry.pointee.timestamp
            let (step, stepOverflow) = timestamp.subtractingReportingOverflow(previous)
            let (elapsed, elapsedOverflow) = timestamp.subtractingReportingOverflow(origin)
            guard !stepOverflow, !elapsedOverflow, step > 0, elapsed > 0 else { return false }
            let samples = av_rescale_q(step, stream.pointee.time_base, sampleBase)
            // Refuse sparse indexes and discontinuities rather than interpreting a gap as drift.
            guard samples >= 1024 - stepTolerance, samples <= 1024 + stepTolerance else { return false }
            let actual = av_rescale_q(elapsed, stream.pointee.time_base, sampleBase)
            let nominal = Int64(index) * 1024
            if actual > nominal + driftThresholdSamples || actual < nominal - driftThresholdSamples {
                needsCorrection = true
            }
            previous = timestamp
        }
        return needsCorrection
    }
}
