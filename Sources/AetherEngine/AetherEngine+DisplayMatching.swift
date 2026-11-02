import Foundation

/// Whether a presentation-only display-matching change preserved the current session.
public enum DisplayMatchingUpdate: Sendable, Equatable {
    /// The policy is installed without changing the player, item, transport or buffers.
    case applied
    /// This pipeline or display owner needs the normal load-options correction instead.
    case requiresReload
    /// The session has not supplied authoritative video facts, or is not playing or paused.
    case notReady
}

extension AetherEngine {
    /// Switch a ready SDR session between fixed-output preview and engine-owned display matching.
    /// HDR pipelines and AVKit/shared-secondary ownership are not changed in place.
    /// A criteria change can still cause an HDMI switch when system frame-rate matching is enabled.
    @discardableResult
    public func updateDisplayMatching(enabled: Bool) -> DisplayMatchingUpdate {
        guard isSessionReady, state == .playing || state == .paused,
              sourceVideoWidth > 0, sourceVideoHeight > 0 else {
            return .notReady
        }
        guard sourceVideoFormat == .sdr, videoFormat == .sdr,
              loadedOptions.sharedOutputRole == .primary,
              loadedOptions.effectiveDisplayCriteriaOwner != .avKit else {
            return .requiresReload
        }

        var options = loadedOptions
        options.displayCriteriaOwner = enabled ? .engine : .host
        options.suppressDisplayCriteria = !enabled
        options.matchContentEnabled = enabled
        applySessionOptionCorrection(options)

        if enabled {
            // Zero omits the rate hint; nil would invent the controller's 24 fps default.
            let rate = sourceVideoFrameRate.flatMap(FrameRateSnap.snap) ?? 0
            displayCriteria.apply(
                format: .sdr, frameRate: rate, codecTag: nil, omitColorExtensions: false
            )
        } else {
            displayCriteria.reset()
        }
        EngineLog.emit("[DisplayCriteria] SDR policy updated in place: matching=\(enabled)", category: .engine)
        return .applied
    }
}
