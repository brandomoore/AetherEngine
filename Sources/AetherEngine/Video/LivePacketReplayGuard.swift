import CryptoKit
import Foundation

/// Conservatively removes packets that a live origin sends a second time after reconnecting.
/// Source timestamps alone are not evidence of a replay: an encoder can reset its clock while
/// continuing with new pictures. A packet is removed only when its source timestamps AND its
/// compressed payload match a packet that this producer already accepted.
///
/// The guard is pump-thread-only. Its history is bounded in both source time and packet count;
/// it stores digests, never video or audio payloads. A mismatch is always forwarded so the normal
/// timeline-rebase path can handle a genuine programme boundary without losing new content.
struct LivePacketReplayGuard {
    enum Stream: Hashable { case video, audio }

    struct Signature: Hashable {
        let stream: Stream
        let dts: Int64
        let pts: Int64
        let digest: SHA256.Digest

        init(stream: Stream, dts: Int64, pts: Int64, payload: Data) {
            self.init(stream: stream, dts: dts, pts: pts, digest: SHA256.hash(data: payload))
        }

        /// Hashes the packet's own buffer: every live packet passes through here, so no copy.
        init(stream: Stream, dts: Int64, pts: Int64, payload: UnsafeRawBufferPointer) {
            self.init(stream: stream, dts: dts, pts: pts, digest: SHA256.hash(data: payload))
        }

        private init(stream: Stream, dts: Int64, pts: Int64, digest: SHA256.Digest) {
            self.stream = stream
            self.dts = dts
            self.pts = pts
            self.digest = digest
        }
    }

    enum Event: Equatable {
        case began
        case finished(videoPackets: Int, audioPackets: Int, videoSeconds: Double)
        case mismatch(videoPackets: Int, audioPackets: Int)
    }

    struct Decision {
        let drop: Bool
        let event: Event?
    }

    private struct Entry {
        let signature: Signature
        let sourceSeconds: Double
    }

    private struct Overlap {
        let videoFrontier: Int64
        let audioFrontier: Int64
        var videoFinished = false
        var audioFinished = false
        var videoPackets = 0
        var audioPackets = 0
        var firstVideoSeconds: Double?
        var lastVideoSeconds: Double?
    }

    private static let historySeconds = 45.0
    private static let maximumEntries = 10_000
    private static let backwardTriggerSeconds = 1.5

    private var entries: [Entry] = []
    private var firstEntry = 0
    private var signatureCounts: [Signature: Int] = [:]
    private var overlap: Overlap?

    var isDroppingReplay: Bool { overlap != nil }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        firstEntry = 0
        signatureCounts.removeAll(keepingCapacity: true)
        overlap = nil
    }

    mutating func record(_ signature: Signature, sourceSeconds: Double) {
        guard sourceSeconds.isFinite else { return }
        entries.append(Entry(signature: signature, sourceSeconds: sourceSeconds))
        signatureCounts[signature, default: 0] += 1
        // Freeze time pruning during a confirmed overlap: the fresh audio/video stream may cross
        // the old frontier at different times, but both still need the same old packet history.
        let cutoff = overlap == nil ? sourceSeconds - Self.historySeconds : -.infinity
        while firstEntry < entries.count,
              (entries[firstEntry].sourceSeconds < cutoff
               || entries.count - firstEntry > Self.maximumEntries) {
            let expired = entries[firstEntry].signature
            if signatureCounts[expired] == 1 {
                signatureCounts.removeValue(forKey: expired)
            } else {
                signatureCounts[expired, default: 0] -= 1
            }
            firstEntry += 1
        }
        if firstEntry > 1_024 {
            entries.removeFirst(firstEntry)
            firstEntry = 0
        }
    }

    mutating func inspect(_ signature: Signature, sourceSeconds: Double, timeBaseSeconds: Double,
                          videoFrontier: Int64, audioFrontier: Int64) -> Decision {
        guard sourceSeconds.isFinite, timeBaseSeconds > 0, signature.dts != Int64.min else {
            return Decision(drop: false, event: nil)
        }

        if overlap == nil {
            let frontier = signature.stream == .video ? videoFrontier : audioFrontier
            guard frontier != Int64.min,
                  (Double(frontier) - Double(signature.dts)) * timeBaseSeconds
                    >= Self.backwardTriggerSeconds,
                  signatureCounts[signature] != nil else {
                return Decision(drop: false, event: nil)
            }
            overlap = Overlap(videoFrontier: videoFrontier, audioFrontier: audioFrontier,
                              videoFinished: false, audioFinished: audioFrontier == Int64.min)
            return dropMatched(signature, sourceSeconds: sourceSeconds, event: .began)
        }

        var current = overlap!
        let frontier = signature.stream == .video ? current.videoFrontier : current.audioFrontier
        if frontier != Int64.min, signature.dts <= frontier {
            guard signatureCounts[signature] != nil else {
                overlap = nil
                return Decision(drop: false,
                                event: .mismatch(videoPackets: current.videoPackets,
                                                 audioPackets: current.audioPackets))
            }
            return dropMatched(signature, sourceSeconds: sourceSeconds, event: nil)
        }

        if signature.stream == .video { current.videoFinished = true }
        else { current.audioFinished = true }
        if current.videoFinished && current.audioFinished {
            overlap = nil
            return Decision(drop: false, event: .finished(
                videoPackets: current.videoPackets, audioPackets: current.audioPackets,
                videoSeconds: max(0, (current.lastVideoSeconds ?? 0) - (current.firstVideoSeconds ?? 0))))
        }
        overlap = current
        return Decision(drop: false, event: nil)
    }

    private mutating func dropMatched(_ signature: Signature, sourceSeconds: Double,
                                      event: Event?) -> Decision {
        var current = overlap!
        if signature.stream == .video {
            current.videoPackets += 1
            if current.firstVideoSeconds == nil { current.firstVideoSeconds = sourceSeconds }
            current.lastVideoSeconds = sourceSeconds
        } else {
            current.audioPackets += 1
        }
        overlap = current
        return Decision(drop: true, event: event)
    }
}
