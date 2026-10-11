import Foundation

/// Caller-selected retention limits for native loopback and opted-in software live DVR.
/// This is a retention allowance, not a synchronous quota for muxer staging or recordings.
public struct LiveDVRLimits: Equatable, Sendable {
    public let windowSeconds: Double?
    public let maximumBytes: Int64
    public let minimumFreeBytes: Int64
    /// Monotonic uptime deadline of the caller's capacity sample, on the systemUptime clock.
    /// Missing, nonfinite or expired deadlines authorize no optional history.
    public let capacityValidUntil: Double?

    public init(windowSeconds: Double?, maximumBytes: Int64, minimumFreeBytes: Int64,
                capacityValidUntil: Double? = nil) {
        self.windowSeconds = windowSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.maximumBytes = max(0, maximumBytes)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.capacityValidUntil = capacityValidUntil
    }

    /// Existing resident payload is reclaimable capacity; never count it twice against free space.
    func retentionBytes(availableBytes: Int64?, residentBytes: Int) -> Int {
        guard windowSeconds != nil, let availableBytes, availableBytes >= minimumFreeBytes else { return 0 }
        let freeHeadroom = min(maximumBytes, availableBytes - minimumFreeBytes)
        let reclaimable = min(maximumBytes - freeHeadroom, Int64(max(0, residentBytes)))
        // Preserve the existing quarter-volume allowance. Add only bounded reclaimable payload,
        // rather than a shrinking free-only cap that would evict its own cache repeatedly.
        let quarterAllowance = min(maximumBytes, availableBytes / 4 + min(maximumBytes, Int64(max(0, residentBytes))) / 4)
        return Int(min(freeHeadroom + reclaimable, quarterAllowance))
    }
}

/// One leaf lock shared by playlist sizing, the producer's cap and finalized-segment retention.
/// Caller must renew with a newly sampled capacity. An expired/missing lease keeps only playback
/// cushions, disables seek, and cannot authorize optional history or an expanded software spool.
final class LiveDVRRetentionPolicy: @unchecked Sendable {
    struct Snapshot {
        let windowSeconds: Double?
        let retentionBytes: Int
    }
    private let lock = NSLock()
    private var value: Snapshot?
    private var validUntil: Double = 0
    private let now: @Sendable () -> Double

    init(now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }
    func update(_ limits: LiveDVRLimits, availableBytes: Int64?, residentBytes: Int) {
        let bytes = limits.retentionBytes(availableBytes: availableBytes, residentBytes: residentBytes)
        let instant = now()
        lock.lock()
        value = Snapshot(windowSeconds: bytes > 0 ? limits.windowSeconds : nil, retentionBytes: bytes)
        validUntil = limits.capacityValidUntil.flatMap { $0.isFinite && instant.isFinite ? $0 : nil }
            ?? -.infinity
        lock.unlock()
    }
    var snapshot: Snapshot? {
        let instant = now()
        lock.lock(); defer { lock.unlock() }
        guard let value else { return nil } // unconfigured behavior stays unchanged
        guard instant.isFinite, instant <= validUntil else {
            return Snapshot(windowSeconds: nil, retentionBytes: 0)
        }
        return value
    }
}
