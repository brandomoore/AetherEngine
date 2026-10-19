/// Who writes `AVDisplayManager.preferredDisplayCriteria` for a load (AE#842). See `LoadOptions.displayCriteriaOwner`.
public enum DisplayCriteriaOwner: String, Sendable, Equatable {
    /// The engine writes range and rate before the item loads and waits for the switch. The default.
    case engine
    /// AVKit writes them from the `AVPlayerItem` (`AVPlayerViewController.appliesPreferredDisplayCriteriaAutomatically`),
    /// somewhere inside the load. The engine holds play() up to a second for that write on HDR and Dolby Vision
    /// content, and does not read the panel, because a readout before AVKit's write would be stale.
    /// `suppressDisplayCriteria = true` is the older spelling of this case.
    case avKit
    /// The host decides before `load()`: it writes criteria of its own (rate-only, say), or none, so the panel
    /// stays in the output format the user chose in tvOS Settings. The engine never writes, waits for no
    /// write it was not told about, reads the panel as on its own path, and still waits out a switch it sees
    /// running when the play gate opens.
    case host
}

extension LoadOptions {
    /// The owner this load runs under. An explicit `displayCriteriaOwner` other than `.engine` wins;
    /// otherwise `suppressDisplayCriteria` keeps its historical meaning, AVKit.
    var effectiveDisplayCriteriaOwner: DisplayCriteriaOwner {
        if displayCriteriaOwner != .engine { return displayCriteriaOwner }
        return suppressDisplayCriteria ? .avKit : .engine
    }

    var engineWritesDisplayCriteria: Bool { effectiveDisplayCriteriaOwner == .engine }

    /// Whether a criteria write may still land inside the load, from a writer whose timing the engine does
    /// not control. Only AVKit's does; the engine's and the host's happened before the item was built.
    var awaitsInboundCriteriaWrite: Bool { effectiveDisplayCriteriaOwner == .avKit }
}
