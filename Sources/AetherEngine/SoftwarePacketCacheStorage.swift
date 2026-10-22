/// Storage for seekable software VOD compressed packets. Native HLS segment caching is unchanged.
public enum SoftwarePacketCacheStorage: String, Sendable, Equatable, CaseIterable {
    /// Follow upstream platform policy: purgeable memory on tvOS, disk elsewhere.
    case automatic
    /// Retain packets in temporary files using the session byte budget and volume safeguards.
    case disk
    /// Use the upstream bounded purgeable-memory store; played history may be reclaimed.
    case memory
}
