import Foundation
import QuartzCore
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A transparent surface for a host that renders the native path through AVKit rather than through
/// `AetherPlayerView`, so the engine has somewhere to hold the picture across the item swap of an
/// audio-track switch (`replaceCurrentItem` blanks the player layer until the next item's first
/// frame). Place it above the video and below the host's own chrome, for instance at the top of
/// `AVPlayerViewController.contentOverlayView`, and hand it to `AetherEngine.bindStillView(_:)`. It
/// draws nothing and takes no input outside that window.
@MainActor
public final class AetherStillView: PlatformBaseView, HeldStillSurface {

    /// How the held picture fills the view. Set it to the fill the host's own player uses, since the
    /// engine's `videoGravity` does not reach an AVKit-rendered picture.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect

    private let presenter = HeldStillPresenter()

    #if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        presenter.layout(bounds)
    }
    #elseif canImport(AppKit)
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    public override func layout() {
        super.layout()
        presenter.layout(bounds)
    }
    #endif

    func showStill(_ frame: CVPixelBuffer, gravity: AVLayerVideoGravity, isHDR: Bool) -> Bool {
        let host: CALayer? = layer
        return presenter.show(frame, gravity: videoGravity, isHDR: isHDR, on: host, bounds: bounds)
    }

    func clearStill() { presenter.clear() }

    var isHoldingStill: Bool { presenter.layer != nil }
}
