import Foundation
import CoreGraphics

/// Measured picture bounds, not permission to discard everything outside them.
public enum ActivePictureState: Sendable, Equatable {
    public enum UnknownReason: Sendable, Equatable {
        case disabled, unavailable, unsupportedColor, unsupportedGeometry
        case insufficientEvidence, expired, discontinuity
    }

    case unknown(UnknownReason)
    case measured(ActivePictureObservation)
}

public struct ActivePictureObservation: Sendable, Equatable {
    public enum Evidence: Sendable { case sampledPixels }

    /// Top-left origin, normalized to the upright, clean-aperture/SAR-corrected
    /// full display canvas, before a host's zoom. Full frame is (0, 0, 1, 1).
    public let normalizedRect: CGRect
    public let displaySize: CGSize
    public let evidence: Evidence
    /// Native uses the AVPlayer item's clock; software uses the source clock.
    public let presentationTime: Double
    public let validUntil: Double
    /// Changes on timeline or geometry invalidation. It is not a frame counter.
    public let generation: UInt64
}

struct ActivePictureStability {
    static let maximumAge: Double = 2
    private(set) var accepted: CGRect?
    private var candidate: CGRect?
    private var count = 0
    private var firstTime: Double = 0
    private var lastTime: Double?
    private(set) var evidenceTime: Double?

    static func isValid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
            && rect.width >= 0.5 && rect.height >= 0.5
    }

    mutating func record(_ rect: CGRect?, at time: Double) {
        guard time.isFinite, lastTime.map({ time > $0 }) ?? true else { return }
        if let evidenceTime, time - evidenceTime > Self.maximumAge { self = Self() }
        if let lastTime, time - lastTime > Self.maximumAge { self = Self() }
        lastTime = time
        guard let rect, Self.isValid(rect) else {
            candidate = nil
            count = 0
            return
        }
        // Never hold an inward crop over newly observed edge content.
        if let accepted, !accepted.contains(rect) {
            self.accepted = accepted.union(rect)
        }
        if let accepted, close(accepted, rect) {
            self.accepted = accepted.union(rect)
            evidenceTime = time
            candidate = nil
            count = 0
            return
        }
        if let candidate, close(candidate, rect) {
            self.candidate = candidate.union(rect)
            count += 1
        } else {
            candidate = rect
            firstTime = time
            count = 1
        }
        if rect == CGRect(x: 0, y: 0, width: 1, height: 1)
            || (count >= 3 && time - firstTime >= 1) {
            accepted = candidate
            evidenceTime = time
        } else if accepted != nil {
            evidenceTime = time
        }
    }

    func rect(at time: Double) -> CGRect? {
        guard let evidenceTime, time.isFinite, time >= evidenceTime,
              time - evidenceTime <= Self.maximumAge else { return nil }
        return accepted
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        max(abs(a.minX - b.minX), abs(a.maxX - b.maxX),
            abs(a.minY - b.minY), abs(a.maxY - b.maxY)) <= 0.012
    }
}

/// A spatially bounded, conservative detector. Sampling cannot guarantee that
/// small or transient edge graphics are absent.
enum ActivePictureDetector {
    static func bounds(luma: [UInt8], width: Int, height: Int, blackThreshold: Int = 8) -> CGRect? {
        guard width >= 8, height >= 8, width <= 320, height <= 180,
              luma.count == width * height else { return nil }
        var centerSum = 0
        var centerCount = 0
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width {
                let value = Int(luma[y * width + x])
                if x >= width / 4, x < width * 3 / 4, y >= height / 4, y < height * 3 / 4 {
                    centerSum += value
                    centerCount += 1
                }
                if value > blackThreshold {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        guard centerCount > 0, centerSum / centerCount >= 24, right >= left, bottom >= top else { return nil }
        // Leave one sampled cell around the evidence, rather than cutting on it.
        left = max(0, left - 1); right = min(width, right + 2)
        top = max(0, top - 1); bottom = min(height, bottom + 2)
        let rect = CGRect(x: Double(left) / Double(width), y: Double(top) / Double(height),
                          width: Double(right - left) / Double(width),
                          height: Double(bottom - top) / Double(height))
        return ActivePictureStability.isValid(rect) ? rect : nil
    }
}
