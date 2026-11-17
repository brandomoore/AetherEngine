import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// Audit DEC-106: both FFmpeg hosts decided "this buffer still belongs to the current position" with a
/// seek-generation read and then called `AudioOutput.enqueue`, so a seek whose renderer flush landed
/// between the two parked a pre-seek buffer in the fresh queue (silence until the clock reached its
/// stamp, and on the software host a false rebuffer). The check has to be made under the lock `flush`
/// takes, against an epoch the flush retires.
@Suite("AudioOutput flush epoch (DEC-106)")
struct AudioOutputFlushEpochTests {

    private func makeBuffer(pts: Double, samples: Int = 1024, sampleRate: Int32 = 48000) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: samples * 4,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: samples * 4,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
                                         offsetIntoDestination: 0, dataLength: samples * 4) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
                                        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: sampleRate),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format,
                                   sampleCount: CMItemCount(samples),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    @Test("a buffer decided on before a flush is refused after it")
    func staleBufferIsRefused() throws {
        let output = AudioOutput()
        let buffer = try #require(makeBuffer(pts: 100))
        let captured = output.epoch
        output.flush()
        #expect(output.enqueue(sampleBuffer: buffer, ifEpoch: captured) == false)
    }

    @Test("a buffer decided on after the flush is accepted")
    func freshBufferIsAccepted() throws {
        let output = AudioOutput()
        output.flush()
        let buffer = try #require(makeBuffer(pts: 100))
        #expect(output.enqueue(sampleBuffer: buffer, ifEpoch: output.epoch))
    }

    @Test("every flush retires the epoch, and stop counts as one")
    func flushAndStopMoveTheEpoch() {
        let output = AudioOutput()
        let start = output.epoch
        output.flush()
        let afterFlush = output.epoch
        #expect(afterFlush != start)
        output.stop()
        #expect(output.epoch != afterFlush)
    }

    private final class Returned: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func set() { lock.withLock { done = true } }
        var isSet: Bool { lock.withLock { done } }
    }

    private final class BufferBox: @unchecked Sendable {
        let buffer: CMSampleBuffer
        init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
    }

    /// AE#549's observer takes the output's lock on whatever thread AVFoundation posts from, and `enqueue`
    /// now holds that lock across `renderer.enqueue`. A renderer that posts from inside `enqueue` (the
    /// 27 SDKs move the same condition into the enqueue call itself) would make the feed thread wait on a
    /// lock it already holds, and every later `flush()` / `stop()` / `seekClock()` with it.
    @Test("an automatic-flush notification posted from inside enqueue does not hang the feed",
          .timeLimit(.minutes(3)))
    func automaticFlushPostedInsideEnqueueDoesNotDeadlock() async throws {
        let output = AudioOutput()
        let box = BufferBox(try #require(makeBuffer(pts: 1)))
        output.afterRendererEnqueueForTesting = { [unowned output] in
            NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                                            object: output.renderer)
        }
        let returned = Returned()
        let feed = Thread {
            output.enqueue(sampleBuffer: box.buffer)
            returned.set()
        }
        feed.start()

        // A feed thread parked on a lock it holds itself never returns; the time limit reports that.
        try await waitFor { returned.isSet }

        try await waitFor { output.automaticFlushCount == 1 }
        #expect(output.automaticFlushCount == 1, "the flush still happens, serialized with enqueueing")
    }

    @Test("an unconditional enqueue is untouched by the epoch")
    func unconditionalEnqueueStillEnqueues() throws {
        let output = AudioOutput()
        output.flush()
        let buffer = try #require(makeBuffer(pts: 1))
        #expect(output.enqueue(sampleBuffer: buffer))
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(start: Double, end: Double)] = []
        func append(_ buffer: CMSampleBuffer) {
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let end = start + CMSampleBufferGetDuration(buffer).seconds
            lock.withLock { values.append((start, end)) }
        }
        func take() -> [(start: Double, end: Double)] {
            lock.withLock {
                defer { values.removeAll() }
                return values
            }
        }
    }

    @Test("repeated signed PCM corrections replace queued audio without moving the paused clock or feed epoch")
    func liveCorrectionLeavesVideoClockAndEpochAlone() throws {
        let output = AudioOutput(retainsAudioForLiveSync: true)
        defer { output.stop() }
        output.seekClock(to: CMTime(seconds: 104, preferredTimescale: 48000), rate: 0)
        output.setPlaybackEnabled(false)
        for second in 100..<108 {
            output.enqueue(sampleBuffer: try #require(makeBuffer(pts: Double(second), samples: 48000)))
        }
        #expect(output.canAdjustAudioDelayLive)
        let epoch = output.epoch
        let revision = output.clockCommandRevision
        let delivered = Delivered()
        output.didEnqueueSampleBufferForTesting = { delivered.append($0) }
        for offset in [0.01, 0.02, -0.01, -0.02, 2, -2, 0] {
            #expect(output.setPresentationOffsetLive(seconds: offset))
            let replay = delivered.take()
            let first = try #require(replay.first)
            let last = try #require(replay.last)
            #expect(abs(first.start - 104) <= 1.0 / 48000 + 0.000001)
            #expect(abs(last.end - (108 + offset)) < 0.0001)
            #expect(output.epoch == epoch)
            #expect(output.clockCommandRevision == revision)
            #expect(output.rate == 0)
            #expect(abs(output.currentTime.seconds - 104) < 0.0001)
        }
        #expect(output.enqueue(sampleBuffer: try #require(makeBuffer(pts: 108)), ifEpoch: epoch))
    }

    @Test("a failed correction keeps queued audio and the existing delay intact")
    func unavailableHistoryDoesNotFlushOrChangeOffset() throws {
        let output = AudioOutput(retainsAudioForLiveSync: true)
        defer { output.stop() }
        output.seekClock(to: CMTime(seconds: 104, preferredTimescale: 48000), rate: 0)
        output.setPresentationOffset(seconds: 0.1)
        output.enqueue(sampleBuffer: try #require(makeBuffer(pts: 104, samples: 48000)))
        #expect(!output.canAdjustAudioDelayLive)
        let delivered = Delivered()
        output.didEnqueueSampleBufferForTesting = { delivered.append($0) }
        #expect(!output.setPresentationOffsetLive(seconds: 2))
        #expect(!output.setPresentationOffsetLive(seconds: .nan))
        #expect(delivered.take().isEmpty)
        output.enqueue(sampleBuffer: try #require(makeBuffer(pts: 105)))
        #expect(abs(try #require(delivered.take().first).start - 105.1) < 0.0001)
    }

    @Test("seek and stop discard the replay history and stale feed cannot repopulate it")
    func flushInvalidatesLiveCorrectionHistory() throws {
        let output = AudioOutput(retainsAudioForLiveSync: true)
        defer { output.stop() }
        output.seekClock(to: CMTime(seconds: 104, preferredTimescale: 48000), rate: 0)
        for second in 100..<108 {
            output.enqueue(sampleBuffer: try #require(makeBuffer(pts: Double(second), samples: 48000)))
        }
        let epoch = output.epoch
        output.flush()
        #expect(!output.canAdjustAudioDelayLive)
        #expect(!output.setPresentationOffsetLive(seconds: 0.01))
        #expect(!output.enqueue(sampleBuffer: try #require(makeBuffer(pts: 104)), ifEpoch: epoch))
        output.enqueue(sampleBuffer: try #require(makeBuffer(pts: 104, samples: 48000)))
        output.stop()
        #expect(!output.setPresentationOffsetLive(seconds: -0.01))
    }

    @Test("PCM history remains bounded and discontinuities cannot replay old audio")
    func replayWindowIsBoundedAndContiguous() throws {
        var history = AudioDelayBuffer()
        for second in 0..<24 {
            history.append(try #require(makeBuffer(pts: Double(second), samples: 48000)), clock: 0)
        }
        #expect(!history.covers(sourceTime: 2))
        #expect(history.covers(sourceTime: 22))
        #expect(history.byteCount <= AudioDelayBuffer.maximumBytes)
        #expect(history.entries.count <= 9)
        history.append(try #require(makeBuffer(pts: 40)), clock: 40)
        #expect(!history.covers(sourceTime: 22))
        #expect(history.covers(sourceTime: 40))
    }

    @Test("large PCM buffers respect the byte ceiling even inside the retained time window")
    func replayWindowHonorsByteLimit() throws {
        var history = AudioDelayBuffer()
        for part in 0..<20 {
            history.append(try #require(makeBuffer(pts: Double(part) / 4, samples: 250_000,
                                                  sampleRate: 1_000_000)), clock: 0)
        }
        #expect(history.byteCount <= AudioDelayBuffer.maximumBytes)
        #expect(history.entries.count == 16)
        #expect(!history.covers(sourceTime: 0))
        #expect(history.covers(sourceTime: 4.5))
    }

    @Test("sub-buffer corrections crop PCM samples without mutating retained source timestamps")
    func replayCropsPCMAtTheRequestedSourceSample() throws {
        var history = AudioDelayBuffer()
        let source = try #require(makeBuffer(pts: 100, samples: 48000))
        history.append(source, clock: 100)
        let replay = try #require(history.replay(
            sourceTime: 100.01, shift: CMTime(seconds: -0.01, preferredTimescale: 48000)))
        let first = try #require(replay.first)
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(first).seconds - 100) < 0.00003)
        #expect(abs(CMSampleBufferGetNumSamples(first) - 47520) <= 1)
        #expect(CMSampleBufferGetNumSamples(source) == 48000)
        #expect(CMSampleBufferGetPresentationTimeStamp(source).seconds == 100)
    }
}
