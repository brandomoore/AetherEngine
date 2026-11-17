import AVFoundation
import CoreMedia

/// Source-timed PCM retained for an audio-only queue replacement. Owned by AudioOutput's lock.
struct AudioDelayBuffer {
    struct Entry {
        let buffer: CMSampleBuffer
        let start: Double
        let end: Double
        let bytes: Int
        let sampleRate: Double
        let bytesPerFrame: Int
        let format: CMFormatDescription
    }

    static let maximumBytes = 16 * 1024 * 1024
    static let maximumEntries = 4096
    static let maximumDuration = 8.0
    private(set) var entries: [Entry] = []
    private(set) var byteCount = 0

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        byteCount = 0
    }

    mutating func append(_ buffer: CMSampleBuffer, clock: Double) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              asbd.mBytesPerFrame > 0,
              asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
              let data = CMSampleBufferGetDataBuffer(buffer) else {
            removeAll()
            return
        }
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        let samples = CMSampleBufferGetNumSamples(buffer)
        let bytes = CMBlockBufferGetDataLength(data)
        let end = start + Double(samples) / asbd.mSampleRate
        guard start.isFinite, end.isFinite, end > start, bytes > 0,
              bytes <= Self.maximumBytes, samples <= bytes / Int(asbd.mBytesPerFrame) else {
            removeAll()
            return
        }
        if let last = entries.last,
           abs(last.end - start) > 1.5 / asbd.mSampleRate
            || !CMFormatDescriptionEqual(
                last.format, otherFormatDescription: format
            ) {
            removeAll()
        }
        entries.append(Entry(buffer: buffer, start: start, end: end, bytes: bytes,
                             sampleRate: asbd.mSampleRate, bytesPerFrame: Int(asbd.mBytesPerFrame),
                             format: format))
        byteCount += bytes
        let historyFloor = clock.isFinite ? clock - AudioDelayPolicy.liveAdjustmentRadiusSeconds - 0.1 : -.infinity
        let floor = max(historyFloor, end - Self.maximumDuration)
        var removed = 0
        while removed < entries.count,
              entries[removed].end < floor || byteCount > Self.maximumBytes
                || entries.count - removed > Self.maximumEntries {
            byteCount -= entries[removed].bytes
            removed += 1
        }
        if removed > 0 { entries.removeFirst(removed) }
    }

    func covers(sourceTime: Double) -> Bool {
        guard sourceTime.isFinite, let first = entries.first, let last = entries.last else { return false }
        return first.start <= sourceTime && last.end > sourceTime
    }

    /// Prepare everything before flushing, so allocation/retiming failures leave playback untouched.
    func replay(sourceTime: Double, shift: CMTime) -> [CMSampleBuffer]? {
        guard covers(sourceTime: sourceTime) else { return nil }
        var result: [CMSampleBuffer] = []
        for entry in entries where entry.end > sourceTime {
            var source = entry.buffer
            if entry.start < sourceTime {
                let skip = Int(((sourceTime - entry.start) * entry.sampleRate).rounded(.up))
                let count = CMSampleBufferGetNumSamples(source)
                guard skip < count else { continue }
                guard let trimmed = Self.trim(entry, skipping: skip) else { return nil }
                source = trimmed
            }
            let delivered = AudioOutput.retimed(source, by: shift)
            guard shift == .zero || delivered !== source else { return nil }
            result.append(delivered)
        }
        return result.isEmpty ? nil : result
    }

    private static func trim(_ entry: Entry, skipping skip: Int) -> CMSampleBuffer? {
        guard let data = CMSampleBufferGetDataBuffer(entry.buffer) else { return nil }
        let samples = CMSampleBufferGetNumSamples(entry.buffer) - skip
        var slice: CMBlockBuffer?
        guard CMBlockBufferCreateWithBufferReference(
            allocator: kCFAllocatorDefault, referenceBuffer: data,
            offsetToData: skip * entry.bytesPerFrame, dataLength: samples * entry.bytesPerFrame,
            flags: 0, blockBufferOut: &slice
        ) == noErr, let slice else { return nil }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(entry.buffer, at: 0, timingInfoOut: &timing) == noErr,
              timing.duration.isNumeric, timing.duration.seconds > 0 else { return nil }
        let elapsed = CMTimeMultiplyByFloat64(timing.duration, multiplier: Double(skip))
        timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, elapsed)
        if timing.decodeTimeStamp.isNumeric {
            timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, elapsed)
        }
        var size = entry.bytesPerFrame
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: slice, formatDescription: entry.format,
            sampleCount: samples, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result
        ) == noErr, let result else { return nil }
        if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                                                         target: entry.buffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) {
            CMSetAttachments(result, attachments: attachments, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return result
    }
}
