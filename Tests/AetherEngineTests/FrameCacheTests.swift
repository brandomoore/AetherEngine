import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

@Suite("FrameCache")
struct FrameCacheTests {

    /// A 1x1 opaque CGImage to use as a cache payload in tests.
    private func dummyImage() -> CGImage {
        let px: [UInt8] = [0, 0, 0, 255]
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test("Stores and retrieves by bucketed position")
    func storeAndGet() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let img = dummyImage()
        cache.set(img, mode: .thumbnail, seconds: 12.3)
        #expect(cache.get(mode: .thumbnail, seconds: 12.9) === img)
        #expect(cache.get(mode: .thumbnail, seconds: 14.1) == nil)
    }

    @Test("Mode namespaces are independent")
    func modeIsolation() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let img = dummyImage()
        cache.set(img, mode: .thumbnail, seconds: 5.0)
        #expect(cache.get(mode: .snapshot, seconds: 5.0) == nil)
    }

    @Test("Evicts least-recently-used past the per-mode limit")
    func lruEviction() {
        let cache = FrameCache(thumbnailLimit: 2, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let a = dummyImage(), b = dummyImage(), c = dummyImage()
        cache.set(a, mode: .thumbnail, seconds: 1.0)
        cache.set(b, mode: .thumbnail, seconds: 2.0)
        _ = cache.get(mode: .thumbnail, seconds: 1.0)
        cache.set(c, mode: .thumbnail, seconds: 3.0)
        #expect(cache.get(mode: .thumbnail, seconds: 1.0) === a)
        #expect(cache.get(mode: .thumbnail, seconds: 2.0) == nil)
        #expect(cache.get(mode: .thumbnail, seconds: 3.0) === c)
    }

    @Test("Snapshots preserve distinct requests across a frame boundary")
    func snapshotPosition() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 4, thumbnailBucketSeconds: 1.0)
        let a = dummyImage(), b = dummyImage()
        // Even sub-millisecond requests can lie on opposite sides of a frame boundary.
        cache.set(a, mode: .snapshot, seconds: 1.0)
        cache.set(b, mode: .snapshot, seconds: 1.0001)
        #expect(cache.get(mode: .snapshot, seconds: 1.0) === a)
        #expect(cache.get(mode: .snapshot, seconds: 1.0001) === b)
        #expect(cache.get(mode: .snapshot, seconds: 1.0002) == nil)
    }

    @Test("Thumbnail cache distinguishes requested widths")
    func thumbnailDimensions() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let small = dummyImage(), large = dummyImage()
        cache.set(small, mode: .thumbnail, seconds: 2, targetWidth: 160)
        cache.set(large, mode: .thumbnail, seconds: 2, targetWidth: 640)
        #expect(cache.get(mode: .thumbnail, seconds: 2.2, targetWidth: 160) === small)
        #expect(cache.get(mode: .thumbnail, seconds: 2.2, targetWidth: 640) === large)
        #expect(cache.get(mode: .thumbnail, seconds: 2.2, targetWidth: 320) == nil)
    }

    @Test("Snapshot cache distinguishes native and both requested dimensions")
    func snapshotDimensions() {
        let cache = FrameCache(thumbnailLimit: 2, snapshotLimit: 4, thumbnailBucketSeconds: 1.0)
        let native = dummyImage(), wide = dummyImage(), short = dummyImage()
        cache.set(native, mode: .snapshot, seconds: 2)
        cache.set(wide, mode: .snapshot, seconds: 2, maxSize: CGSize(width: 320, height: 240))
        cache.set(short, mode: .snapshot, seconds: 2, maxSize: CGSize(width: 320, height: 120))
        #expect(cache.get(mode: .snapshot, seconds: 2) === native)
        #expect(cache.get(mode: .snapshot, seconds: 2, maxSize: CGSize(width: 320, height: 240)) === wide)
        #expect(cache.get(mode: .snapshot, seconds: 2, maxSize: CGSize(width: 320, height: 120)) === short)
        #expect(cache.get(mode: .snapshot, seconds: 2, maxSize: CGSize(width: 640, height: 240)) == nil)
    }

    @Test("Size variants share the same per-mode count limit")
    func sizeVariantEviction() {
        let cache = FrameCache(thumbnailLimit: 2, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let a = dummyImage(), b = dummyImage(), c = dummyImage()
        cache.set(a, mode: .thumbnail, seconds: 1, targetWidth: 160)
        cache.set(b, mode: .thumbnail, seconds: 1, targetWidth: 320)
        _ = cache.get(mode: .thumbnail, seconds: 1, targetWidth: 160)
        cache.set(c, mode: .thumbnail, seconds: 1, targetWidth: 640)
        #expect(cache.get(mode: .thumbnail, seconds: 1, targetWidth: 160) === a)
        #expect(cache.get(mode: .thumbnail, seconds: 1, targetWidth: 320) == nil)
        #expect(cache.get(mode: .thumbnail, seconds: 1, targetWidth: 640) === c)
    }

    @Test("Preview positions and widths are independent and the preview cache stays bounded")
    func previewCache() {
        let cache = FrameCache(thumbnailLimit: 2, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let small = dummyImage(), large = dummyImage(), next = dummyImage()
        cache.set(small, mode: .preview, seconds: 1, targetWidth: 160)
        cache.set(large, mode: .preview, seconds: 1, targetWidth: 320)
        #expect(cache.get(mode: .preview, seconds: 1, targetWidth: 160) === small)
        #expect(cache.get(mode: .preview, seconds: 1.0001, targetWidth: 160) == nil)
        #expect(cache.get(mode: .thumbnail, seconds: 1) == nil)
        #expect(cache.get(mode: .snapshot, seconds: 1) == nil)
        cache.set(next, mode: .preview, seconds: 1.0001, targetWidth: 160)
        #expect(cache.get(mode: .preview, seconds: 1, targetWidth: 320) == nil)
        #expect(cache.get(mode: .preview, seconds: 1, targetWidth: 160) === small)
        #expect(cache.get(mode: .preview, seconds: 1.0001, targetWidth: 160) === next)
        cache.clear()
        #expect(cache.get(mode: .preview, seconds: 1, targetWidth: 160) == nil)
    }

    @Test("clear empties the cache")
    func clear() {
        let cache = FrameCache(thumbnailLimit: 4, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        cache.set(dummyImage(), mode: .thumbnail, seconds: 1.0)
        cache.set(dummyImage(), mode: .snapshot, seconds: 2.0)
        cache.clear()
        #expect(cache.get(mode: .thumbnail, seconds: 1.0) == nil)
        #expect(cache.get(mode: .snapshot, seconds: 2.0) == nil)
    }

    @Test("Thumbnail eviction does not affect snapshot store")
    func perModeLimitIndependence() {
        let cache = FrameCache(thumbnailLimit: 2, snapshotLimit: 2, thumbnailBucketSeconds: 1.0)
        let snap = dummyImage()
        cache.set(snap, mode: .snapshot, seconds: 5.0)
        cache.set(dummyImage(), mode: .thumbnail, seconds: 10.0)
        cache.set(dummyImage(), mode: .thumbnail, seconds: 20.0)
        cache.set(dummyImage(), mode: .thumbnail, seconds: 30.0)
        #expect(cache.get(mode: .snapshot, seconds: 5.0) === snap)
    }
}
