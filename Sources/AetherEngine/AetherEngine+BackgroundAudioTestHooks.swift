#if DEBUG
import Foundation

// Test-only hooks for the aetherctl `bgaudio` harness. The SW-path background-audio keepalive is normally
// driven by the iOS app lifecycle (UIApplication.didEnterBackground), which does not exist on macOS, so the
// CLI toggles it directly. DEBUG-gated: absent from Release builds, so this is never shipped API.
extension AetherEngine {

    /// Enter / leave SW-path background-audio-only. No-op when the active backend is not the software host.
    @MainActor
    public func setSoftwareBackgroundAudioOnlyForTesting(_ on: Bool) {
        if on {
            softwareHost?.enterBackgroundAudioOnly()
        } else {
            softwareHost?.exitBackgroundAudioOnly()
        }
    }

    /// AE#739: invalidate the SW host's VideoToolbox session the way an iOS screen lock does. Returns false
    /// when the active video decoder is not the hardware one.
    @MainActor
    public func invalidateSoftwareVideoSessionForTesting() -> Bool {
        softwareHost?.invalidateVideoSessionForTesting() ?? false
    }

    /// Count of video frames the SW host has enqueued. Flat while background-audio-only drops video; rises
    /// again on foreground return. nil when the active backend is not the software host.
    @MainActor
    public var softwareVideoFramesEnqueuedForTesting: Int? {
        softwareHost?.framesEnqueued
    }
}
#endif
