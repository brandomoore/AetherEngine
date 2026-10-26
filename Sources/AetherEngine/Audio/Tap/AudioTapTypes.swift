import Foundation
import AVFAudio

/// One decoded tap buffer (#95). Handed to exactly one consumer via `AsyncStream`; the engine
/// never touches `buffer` after yielding it, which is the invariant behind `@unchecked Sendable`.
public struct AudioTapBuffer: @unchecked Sendable {
    /// Mono Float32 48 kHz PCM (see `AetherEngine.audioTapFormat`).
    public let buffer: AVAudioPCMBuffer
    /// Source-PTS seconds of the first sample, same axis as `AetherEngine.sourceTime`.
    public let sourceTime: Double
    /// True when this buffer does not abut the previous one (seek, gap, drop, track switch).
    /// Non-discontinuity buffers are guaranteed strictly increasing and non-overlapping on
    /// `sourceTime` (AudioTapMonotonicFilter trims sub-`overlapTrimThreshold` seam overlaps),
    /// which SpeechAnalyzer's input timeline requires.
    public let discontinuity: Bool
}

public extension AetherEngine {
    /// The fixed output format of the audio tap. Computed per call because `AVAudioFormat`
    /// is not Sendable and cannot be a stored static under strict concurrency.
    nonisolated static var audioTapFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    }
}

enum AudioTapDefaults {
    static let leadSeconds: Double = 10
    static let toleranceSeconds: Double = 2
    static let minSamplesPerChunk = 4800   // 100 ms at 48 kHz
    static let sampleRate: Double = 48_000
    /// Max backward PTS overlap (seconds) the monotonic gate trims silently. Segment-seam
    /// decoder priming is tens of ms; a larger backward jump is a real seek and is passed
    /// through as a discontinuity instead.
    static let overlapTrimThreshold: Double = 0.25
}

/// Pure pacing decision for the tap readers (#95). Playlist-axis seconds on all inputs.
enum AudioTapPacing {
    enum Decision: Equatable {
        case decodeNext   // decode the segment after the last decoded one
        case sleep        // full lead decoded; idle and recheck
        case reanchor     // playhead moved away; jump to the playhead's segment
    }

    /// `previousPlayhead` is the playhead the reader saw on its previous step. A backward seek is
    /// read off the playhead itself, never off how far the decode runs ahead of it: a reader
    /// decodes whole segments, so one long segment legitimately overshoots the lead, and treating
    /// that overshoot as a seek re-decoded the same segments forever (#864).
    static func decide(lastDecodedEndPTS: Double?, playhead: Double, previousPlayhead: Double?,
                       leadSeconds: Double, toleranceSeconds: Double) -> Decision {
        guard let last = lastDecodedEndPTS else { return .decodeNext }
        if let previousPlayhead, playhead < previousPlayhead - toleranceSeconds { return .reanchor }
        if last < playhead - toleranceSeconds { return .reanchor }
        if last - playhead >= leadSeconds { return .sleep }
        return .decodeNext
    }
}

/// Decoded tap buffers waiting for the playhead (#864). A reader decodes a whole segment at a
/// time, and a long-GOP source cuts segments of 15 s and more: yielded in one burst, that is
/// over a hundred buffers into a stream that keeps the newest few hundred at most, so a
/// consumer lost audio however fast it drained. Held buffers are released once they start
/// before playhead + lead, and the ones that already ended behind the playhead (the head of
/// the segment an anchor lands in) are dropped, which bounds what is in flight to
/// tolerance + lead.
struct AudioTapHeldBuffers {
    private var items: [(start: Double, buffer: AudioTapBuffer)] = []

    var isEmpty: Bool { items.isEmpty }

    /// `start` is the playlist-axis time of the buffer's first sample.
    mutating func append(start: Double, buffer: AudioTapBuffer) {
        items.append((start, buffer))
    }

    mutating func clear() { items.removeAll() }

    /// Emits, in order, every held buffer that starts before `limit`, dropping the ones that
    /// end before `floor`. A dropped buffer's discontinuity moves to the next one emitted.
    /// Returns the playlist-axis end of the last buffer consumed, emitted or dropped, nil when
    /// none was due. A dropped one counts: a reader whose whole release fell behind the playhead
    /// (a forward seek before the anchor decode landed) must see that end to reanchor.
    mutating func release(before limit: Double, droppingEndsBefore floor: Double,
                          emit: (AudioTapBuffer) -> Void) -> Double? {
        var end: Double?
        var consumed = 0
        var carriedDiscontinuity = false
        for item in items {
            guard item.start < limit else { break }
            consumed += 1
            let itemEnd = item.start + Double(item.buffer.buffer.frameLength) / AudioTapDefaults.sampleRate
            end = itemEnd
            guard itemEnd >= floor else {
                carriedDiscontinuity = carriedDiscontinuity || item.buffer.discontinuity
                continue
            }
            emit(AudioTapBuffer(buffer: item.buffer.buffer, sourceTime: item.buffer.sourceTime,
                                discontinuity: item.buffer.discontinuity || carriedDiscontinuity))
            carriedDiscontinuity = false
        }
        items.removeFirst(consumed)
        if carriedDiscontinuity, let next = items.first {
            items[0] = (next.start, AudioTapBuffer(buffer: next.buffer.buffer,
                                                   sourceTime: next.buffer.sourceTime,
                                                   discontinuity: true))
        }
        return end
    }
}
