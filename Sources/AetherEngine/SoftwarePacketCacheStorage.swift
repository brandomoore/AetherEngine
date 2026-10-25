/// Storage for seekable software VOD compressed packets. Native HLS segment caching is unchanged.
public enum SoftwarePacketCacheStorage: String, Sendable, Equatable, CaseIterable {
    /// Follow upstream platform policy: purgeable memory on tvOS, disk elsewhere.
    case automatic
    /// Retain packets in temporary files using the session byte budget and volume safeguards.
    case disk
    /// Use the upstream bounded purgeable-memory store; played history may be reclaimed.
    case memory
}

/// A metadata-only snapshot of the active compressed-packet read-ahead store.
/// Byte counts are not playable duration. Memory budgets exclude purgeable played history;
/// disk budgets include retained history and protected chunk slack.
public struct SoftwareReadAheadStatus: Sendable, Equatable {
    public enum Storage: Sendable, Equatable {
        case memory, disk
    }
    public let storage: Storage
    public let queuedBytes: Int
    public let budgetedBytes: Int
    public let byteBudget: Int
    public let targetSeconds: Double
    public let byteLimitReached: Bool

    public init(storage: Storage, queuedBytes: Int, budgetedBytes: Int,
                byteBudget: Int, targetSeconds: Double, byteLimitReached: Bool) {
        self.storage = storage
        self.queuedBytes = queuedBytes
        self.budgetedBytes = budgetedBytes
        self.byteBudget = byteBudget
        self.targetSeconds = targetSeconds
        self.byteLimitReached = byteLimitReached
    }
}
