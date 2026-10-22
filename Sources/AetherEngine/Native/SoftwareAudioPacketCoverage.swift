import Foundation

/// Exact decoded sample geometry, admitted by the host from codec/stream metadata. Never bitrate.
/// Unknown, reservoir-dependent and variable-frame codecs retain strict packet coverage.
struct SoftwareAudioPacketTiming: Sendable {
    enum Layout: Sendable {
        case fixed(samples: Int32, packetBytes: Int?)
        case pcm(bytesPerSampleFrame: Int)
    }
    let sampleRate: Int32
    let layout: Layout

    func samples(byteCount: Int) -> Int64? {
        guard sampleRate > 0, sampleRate <= 768_000, byteCount > 0 else { return nil }
        let result: Int64
        switch layout {
        case let .fixed(samples, packetBytes):
            guard packetBytes == nil || packetBytes == byteCount else { return nil }
            result = Int64(samples)
        case let .pcm(bytesPerSampleFrame):
            guard bytesPerSampleFrame > 0, byteCount % bytesPerSampleFrame == 0 else { return nil }
            result = Int64(byteCount / bytesPerSampleFrame)
        }
        guard result > 0, result <= Int64(sampleRate) / 2 else { return nil }
        return result
    }
}

/// Audio coverage uses the same strict interval set as video/seek. Only a verified sample clock
/// may join quantized endpoints. Carrying the feasible fractional phase across packets prevents
/// accepting an extra tick on every packet (a fixed epsilon merge would silently accumulate it).
/// All state is O(1) besides the existing bounded interval set; no packet data or decoding is kept.
struct SoftwareAudioPacketCoverage: Sendable {
    private var coverage: SoftwarePacketCoverage
    private let numerator: Int32
    private let denominator: Int32
    private let timing: SoftwareAudioPacketTiming?
    private var previousPTS: Int64?
    private var previousSamples: Int64?
    private var phaseLow: Int64 = 0
    private var phaseHigh: Int64 = 0

    init(timeBaseNumerator: Int32, timeBaseDenominator: Int32,
         timing: SoftwareAudioPacketTiming? = nil, maximumRangeCount: Int = 4096) {
        numerator = timeBaseNumerator
        denominator = timeBaseDenominator
        self.timing = timing
        coverage = SoftwarePacketCoverage(maximumRangeCount: maximumRangeCount)
    }

    var isFull: Bool { coverage.isFull }
    var rangeCount: Int { coverage.rangeCount }
    func rangesSeconds(timeBaseNumerator: Int32, timeBaseDenominator: Int32) -> [ClosedRange<Double>] {
        coverage.rangesSeconds(timeBaseNumerator: timeBaseNumerator, timeBaseDenominator: timeBaseDenominator)
    }
    func frontierSeconds(containing seconds: Double, timeBaseNumerator: Int32,
                         timeBaseDenominator: Int32) -> Double? {
        coverage.frontierSeconds(containing: seconds, timeBaseNumerator: timeBaseNumerator,
                                 timeBaseDenominator: timeBaseDenominator)
    }
    mutating func prune(before tick: Int64) { coverage.prune(before: tick) }
    mutating func reset() { coverage.reset(); resetClock() }
    private mutating func resetClock() {
        previousPTS = nil; previousSamples = nil; phaseLow = 0; phaseHigh = 0
    }

    mutating func insert(pts: Int64, duration: Int64, byteCount: Int) {
        guard pts != Int64.min, numerator > 0, denominator > 0 else { resetClock(); return }
        let prior = previousPTS
        let (delta, overflow) = pts.subtractingReportingOverflow(prior ?? pts)
        let samples = verifiedSamples(duration: duration, byteCount: byteCount)
        var joined = false
        if !overflow, delta >= 0, let prior, let samplesBefore = previousSamples,
           samples != nil, let timing {
            let scale = Int64(timing.sampleRate) * Int64(numerator)
            let (ticks, ticksOverflow) = delta.multipliedReportingOverflow(by: scale)
            let (elapsed, elapsedOverflow) = samplesBefore.multipliedReportingOverflow(by: Int64(denominator))
            let (shift, shiftOverflow) = elapsed.subtractingReportingOverflow(ticks)
            let (low, lowOverflow) = phaseLow.addingReportingOverflow(shift)
            let (high, highOverflow) = phaseHigh.addingReportingOverflow(shift)
            if !ticksOverflow, !elapsedOverflow, !shiftOverflow, !lowOverflow, !highOverflow,
               max(0, low) <= min(scale - 1, high) {
                phaseLow = max(0, low); phaseHigh = min(scale - 1, high)
                if delta > 0 { coverage.insert(pts: prior, duration: delta) }
                joined = true
            }
        }
        // Preserve upstream's duration-less audio contract (including repeated sub-ms TrueHD
        // timestamps). A missing/backward/overflowing timestamp breaks the predecessor chain.
        // This fallback does NOT apply to positive durations lacking trustworthy sample geometry.
        // It does apply when admitted geometry fails to join: codecpar can understate the frame
        // (implicit HE-AAC), and without it a duration-less track would cover nothing at all.
        if duration == 0, !joined, !overflow, delta > 0, let prior,
           delta <= Int64(denominator) / (2 * Int64(numerator)) {
            coverage.insert(pts: prior, duration: delta)
        }
        if duration > 0 { coverage.insert(pts: pts, duration: duration) }
        if !joined {
            phaseLow = 0
            phaseHigh = timing.map { Int64($0.sampleRate) * Int64(numerator) - 1 } ?? 0
        }
        previousPTS = pts
        previousSamples = samples
    }

    private func verifiedSamples(duration: Int64, byteCount: Int) -> Int64? {
        guard duration >= 0, let timing, let samples = timing.samples(byteCount: byteCount) else { return nil }
        let scale = Int64(timing.sampleRate) * Int64(numerator)
        let (length, overflow) = samples.multipliedReportingOverflow(by: Int64(denominator))
        guard !overflow, scale > 0 else { return nil }
        let floor = length / scale
        let ceil = floor + (length % scale == 0 ? 0 : 1)
        // A declared duration conflicting with sample geometry is not quantization evidence.
        guard duration == 0 || duration == floor || duration == ceil else { return nil }
        return samples
    }
}
