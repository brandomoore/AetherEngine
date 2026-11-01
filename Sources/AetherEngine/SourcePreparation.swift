import Foundation

/// Why a demux-only packet preparation stopped. Only `complete` traversed the requested window.
public enum SourcePreparationOutcome: Sendable, Equatable {
    case complete
    case endOfSource
    case seekFailed
    case budgetExhausted(ProbeError)
}

public enum SourcePreparationError: Error, Sendable, Equatable {
    case invalidRequest
    case customSourceRequired
    case noMediaStreams
    case invalidAudioStream
    case invalidDiscTitle
}

/// Observed compressed packets, on the folded source timestamp axis. Not decoded or playable coverage.
public struct SourcePreparationStream: Sendable, Equatable {
    public internal(set) var streamIndex: Int32
    public internal(set) var packetCount = 0
    public internal(set) var packetBytes: Int64 = 0
    public internal(set) var untimedPacketCount = 0
    public internal(set) var firstSourceTime: Double?
    public internal(set) var observedSourceRange: ClosedRange<Double>?
    /// A packet-level random-access point, not an index-entry assertion or a decoded-frame witness.
    public internal(set) var randomAccessSourceTime: Double?
}

/// Numeric evidence only. No reader, demux handle, packet payload, URL or credential is retained.
public struct SourcePreparationReport: Sendable, Equatable {
    public internal(set) var outcome: SourcePreparationOutcome
    public internal(set) var requestedPresentationTime: Double
    public internal(set) var requestedPresentationRange: ClosedRange<Double>
    public internal(set) var sourceOrigin: Double?
    public internal(set) var requestedSourceRange: ClosedRange<Double>?
    public internal(set) var selectedDiscTitleID: Int?
    public internal(set) var video: SourcePreparationStream?
    public internal(set) var audio: SourcePreparationStream?
    /// Includes recognition, opening, seeks, rereads and all streams, not just the selected packets.
    public internal(set) var inputBytesRead: Int64 = 0
    public internal(set) var demuxedPackets: Int = 0
}

/// Timestamp evidence is deliberately distinct from a decoder or a cache's residency guarantee.
struct SourcePreparationProgress {
    var stream: SourcePreparationStream
    let isVideo: Bool
    let requestedRange: ClosedRange<Double>
    let timestampTolerance: Double
    private var decodeFrontier: Double?
    private var randomAccessFrontier: Double?
    private var hasStartPacket = false
    private var unknownTiming = false

    init(index: Int32, isVideo: Bool, requestedRange: ClosedRange<Double>, timestampTolerance: Double = 0) {
        stream = SourcePreparationStream(streamIndex: index)
        self.isVideo = isVideo
        self.requestedRange = requestedRange
        self.timestampTolerance = timestampTolerance
    }

    mutating func record(pts: Double?, dts: Double?, duration: Double, bytes: Int,
                         randomAccess: Bool) {
        stream.packetCount += 1
        stream.packetBytes += Int64(max(0, bytes))
        // DTS alone cannot prove presentation coverage of reordered video.
        guard let pts = pts ?? (isVideo ? nil : dts), pts.isFinite else {
            stream.untimedPacketCount += 1
            unknownTiming = true
            return
        }
        let end = pts + max(0, duration)
        guard end.isFinite else {
            stream.untimedPacketCount += 1
            unknownTiming = true
            return
        }
        if stream.firstSourceTime == nil { stream.firstSourceTime = pts }
        let old = stream.observedSourceRange
        stream.observedSourceRange = min(old?.lowerBound ?? pts, pts)...max(old?.upperBound ?? end, end)
        if isVideo, randomAccess {
            if stream.randomAccessSourceTime == nil { stream.randomAccessSourceTime = pts }
            randomAccessFrontier = max(randomAccessFrontier ?? pts, pts)
        }
        if pts <= requestedRange.lowerBound + timestampTolerance,
           end + timestampTolerance >= requestedRange.lowerBound {
            hasStartPacket = true
        }
        if let dts, dts.isFinite {
            decodeFrontier = max(decodeFrontier ?? dts, dts)
        } else if !isVideo {
            decodeFrontier = max(decodeFrontier ?? pts, pts)
        }
    }

    var isComplete: Bool {
        guard !unknownTiming, hasStartPacket,
              let range = stream.observedSourceRange,
              range.upperBound + timestampTolerance >= requestedRange.upperBound else { return false }
        let frontier = decodeFrontier ?? randomAccessFrontier
        guard let frontier, frontier + timestampTolerance >= requestedRange.upperBound else { return false }
        if isVideo {
            guard let start = stream.randomAccessSourceTime,
                  start <= requestedRange.lowerBound + timestampTolerance else { return false }
        }
        return true
    }
}
