import AVFoundation
import Testing

@testable import AetherEngine

@Suite("Active picture")
struct ActivePictureTests {
    @Test("Detects full, letterboxed, pillarboxed, asymmetric and windowboxed pictures")
    func geometry() throws {
        for expected in [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: 0.15, width: 1, height: 0.7),
            CGRect(x: 0.15, y: 0, width: 0.7, height: 1),
            CGRect(x: 0.05, y: 0.1, width: 0.8, height: 0.65),
        ] {
            let actual = try #require(
                ActivePictureDetector.bounds(luma: grid(picture: expected), width: 320, height: 180))
            #expect(actual.contains(expected))
            #expect(abs(actual.minX - expected.minX) < 0.01)
            #expect(abs(actual.maxY - expected.maxY) < 0.02)
        }
    }

    @Test("Dark samples and unsafe extents cannot become a picture")
    func rejection() {
        #expect(
            ActivePictureDetector.bounds(
                luma: [UInt8](repeating: 3, count: 320 * 180), width: 320, height: 180) == nil)
        #expect(
            ActivePictureDetector.bounds(
                luma: grid(picture: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)),
                width: 320, height: 180) == nil)
        #expect(!ActivePictureStability.isValid(CGRect(x: 0, y: 0, width: Double.nan, height: 1)))
        #expect(!ActivePictureStability.isValid(CGRect(x: -0.1, y: 0, width: 1, height: 1)))
    }

    @Test("Edge graphics expand the measured boundary")
    func edgeContent() throws {
        var pixels = grid(picture: CGRect(x: 0, y: 0.15, width: 1, height: 0.7))
        for y in 169..<178 {
            for x in 20..<280 { pixels[y * 320 + x] = 180 }
        }
        let actual = try #require(ActivePictureDetector.bounds(luma: pixels, width: 320, height: 180))
        #expect(actual.maxY > 0.99)
    }

    @Test("Confirmation, duplicates, expiry without frames and expansion")
    func temporal() throws {
        let crop = CGRect(x: 0, y: 0.15, width: 1, height: 0.7)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        var tracker = ActivePictureStability()
        tracker.record(crop, at: 1)
        tracker.record(crop, at: 1)
        tracker.record(crop, at: 1.5)
        #expect(tracker.rect(at: 1.5) == nil)
        tracker.record(crop, at: 2)
        #expect(tracker.rect(at: 2) == crop)
        #expect(tracker.rect(at: 1.9) == nil)
        #expect(tracker.rect(at: 4) == crop)
        #expect(tracker.rect(at: 4.01) == nil)
        tracker.record(crop, at: 2)
        #expect(tracker.rect(at: 4.01) == nil)
        tracker.record(full, at: 4.5)
        #expect(tracker.rect(at: 4.5) == full)
    }

    @Test("SDR BGRA pixels are measured without changing the source buffer")
    func pixels() throws {
        var buffer: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                nil, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = try #require(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<180 {
            for x in 0..<320 {
                let value: UInt8 = (30..<150).contains(y) ? 160 : 0
                let i = y * stride + x * 4
                bytes[i] = value
                bytes[i + 1] = value
                bytes[i + 2] = value
                bytes[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let result = ActivePictureWorker.sample(image)
        #expect(result.failure == nil)
        let rect = try #require(result.bounds)
        #expect(rect.minY > 0.15 && rect.maxY < 0.85)
        CVBufferSetAttachment(
            image, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        #expect(ActivePictureWorker.sample(image).bounds == rect)
        CVBufferSetAttachment(
            image, kCVImageBufferTransferFunctionKey, "unknown-transfer" as CFString, .shouldPropagate)
        #expect(ActivePictureWorker.sample(image).failure == .unsupportedColor)
    }

    @Test(
        "P010 video/full range preserves HDR edge content",
        arguments: [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        ],
        [
            kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
        ])
    func tenBit(format: OSType, transfer: String) throws {
        var buffer: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, format, nil, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        CVBufferSetAttachment(
            image, kCVImageBufferTransferFunctionKey, transfer as CFString, .shouldPropagate)
        let limited = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let black = limited ? 64 : 0
        func fill(edge: Int? = nil, dark: Bool = false) {
            CVPixelBufferLockBaseAddress(image, [])
            defer { CVPixelBufferUnlockBaseAddress(image, []) }
            let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            for y in 0..<180 {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<320 {
                    let value = dark ? black : (30..<150).contains(y) ? 500 : black + 6
                    row[x] = UInt16(y == 0 ? edge ?? value : value) << 6
                }
            }
        }
        fill()
        let rect = try #require(ActivePictureWorker.sample(image).bounds)
        #expect(rect.minY > 0.15 && rect.maxY < 0.85)
        if transfer != kCVImageBufferTransferFunction_ITU_R_709_2 as String {
            fill(edge: black + 20)
            #expect(ActivePictureWorker.sample(image).bounds?.minY == 0)
        }
        fill(dark: true)
        #expect(ActivePictureWorker.sample(image).bounds == nil)
    }

    @Test("Half-float display pixels retain finite near-black edges")
    func halfFloat() throws {
        var buffer: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 320, 180, kCVPixelFormatType_64RGBAHalf,
                nil, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        CVBufferSetAttachment(
            image, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_Linear, .shouldPropagate)
        CVPixelBufferLockBaseAddress(image, [])
        let base = try #require(CVPixelBufferGetBaseAddress(image))
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<180 {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<320 {
                for component in 0..<3 {
                    row[x * 4 + component] = Float16((30..<150).contains(y) ? 0.4 : 0).bitPattern
                }
                row[x * 4 + 3] = Float16(1).bitPattern
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        #expect(ActivePictureWorker.sample(image).bounds?.minY ?? 0 > 0.15)
    }

    @Test("Display rotation and mirroring map asymmetric bounds after sample aspect correction")
    func displayTransforms() {
        let geometry = ActivePictureGeometry(
            codedSize: CGSize(width: 720, height: 576),
            cleanRect: CGRect(x: 0, y: 0, width: 720, height: 576),
            displaySize: CGSize(width: 1024, height: 576), format: 0, transfer: nil)
        let rect = CGRect(x: 0, y: 0.125, width: 1, height: 0.75)
        let clockwise = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 576, ty: 0)
        #expect(ActivePictureGeometry.supports(clockwise))
        let rotated = geometry.upright(rect, transform: clockwise)
        #expect(rotated.rect == CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
        #expect(rotated.size == CGSize(width: 576, height: 1024))
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1024, ty: 0)
        #expect(ActivePictureGeometry.supports(mirror))
        #expect(
            geometry.upright(CGRect(x: 0, y: 0, width: 0.75, height: 1), transform: mirror).rect
                == CGRect(x: 0.25, y: 0, width: 0.75, height: 1))
        #expect(
            !ActivePictureGeometry.supports(CGAffineTransform(a: 1, b: 0, c: 1, d: 1, tx: 0, ty: 0)))
    }

    private func grid(picture: CGRect) -> [UInt8] {
        (0..<(320 * 180)).map { i in
            picture.contains(
                CGPoint(
                    x: (Double(i % 320) + 0.5) / 320,
                    y: (Double(i / 320) + 0.5) / 180)) ? 160 : 0
        }
    }

    @Test("Darkness expires confirmation rather than reviving a stale crop")
    func reacquisition() {
        let crop = CGRect(x: 0, y: 0.15, width: 1, height: 0.7)
        var tracker = ActivePictureStability()
        for time in [0.0, 0.5, 1] { tracker.record(crop, at: time) }
        for time in [1.5, 2, 2.5, 3, 3.5] { tracker.record(nil, at: time) }
        tracker.record(crop, at: 4)
        #expect(tracker.rect(at: 4) == nil)
        tracker.record(crop, at: 4.5)
        #expect(tracker.rect(at: 4.5) == nil)
        tracker.record(crop, at: 5)
        #expect(tracker.rect(at: 5) == crop)
    }

    @Test("Presentation seams do not relabel old or future samples")
    func timeline() throws {
        let timeline = ActivePictureTimeline()
        let before = try #require(timeline.generation(at: 5))
        timeline.markSeam(at: 10)
        let after = try #require(timeline.generation(at: 10))
        #expect(before != after)
        #expect(timeline.generation(at: 9.99) == before)
        #expect(timeline.generation(at: 10.01) == after)
        timeline.invalidate()
        let replayBefore = timeline.generation(at: 9)
        let replayAfter = timeline.generation(at: 10)
        #expect(replayBefore != before)
        #expect(replayAfter != after)
        #expect(replayBefore != replayAfter)
        timeline.reset()
        #expect(timeline.generation(at: 5) != before)
        #expect(timeline.generation(at: 10) != after)
        for time in 0...64 { timeline.markSeam(at: Double(time)) }
        #expect(timeline.generation(at: 65) == nil)
    }

    @Test("Asymmetric clean apertures use top-down pixel rows")
    func cleanAperture() throws {
        var buffer: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
                nil, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        CVBufferSetAttachment(
            image, kCVImageBufferCleanApertureKey,
            [
                kCVImageBufferCleanApertureWidthKey: 320,
                kCVImageBufferCleanApertureHeightKey: 180,
                kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
                kCVImageBufferCleanApertureVerticalOffsetKey: 20,
            ] as CFDictionary, .shouldPropagate)
        let clean = CVImageBufferGetCleanRect(image)
        let top = 240 - Int(clean.maxY)
        try #require(top != Int(clean.minY))
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = try #require(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<240 {
            for x in 0..<320 {
                let i = y * stride + x * 4
                let value: UInt8 = (top..<(top + 180)).contains(y) ? 160 : 0
                bytes[i] = value
                bytes[i + 1] = value
                bytes[i + 2] = value
                bytes[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        #expect(ActivePictureWorker.sample(image).bounds == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("Flush between dequeue and handover cannot relabel the old picture")
    @MainActor func handoverFlush() throws {
        let renderer = SampleBufferRenderer()
        var buffer: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                nil, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        renderer.enqueue(pixelBuffer: image, pts: .zero)
        renderer.beforeActivePictureHandoverForTesting = { [weak renderer] in renderer?.flush() }
        renderer.drainReorderBuffer()
        #expect(renderer.activePictureFrame == nil)
        renderer.beforeActivePictureHandoverForTesting = nil
        renderer.enqueue(pixelBuffer: image, pts: CMTime(seconds: 1, preferredTimescale: 600))
        renderer.drainReorderBuffer()
        #expect(renderer.activePictureFrame?.time == 1)
        renderer.flush()
    }

    @Test(
        "NV12 full/video range use their own black level and display aspect",
        arguments: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
    func nv12(format: OSType) throws {
        var buffer: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(kCFAllocatorDefault, 720, 576, format, nil, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        CVBufferSetAttachment(
            image, kCVImageBufferPixelAspectRatioKey,
            [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 64,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: 45,
            ] as CFDictionary, .shouldPropagate)
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = try #require(CVPixelBufferGetBaseAddressOfPlane(image, 0)).assumingMemoryBound(
            to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        for y in 0..<576 {
            for x in 0..<720 {
                bytes[y * stride + x] =
                    (96..<480).contains(y)
                    ? 160
                    : format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let result = ActivePictureWorker.sample(image)
        let geometry = try #require(result.geometry)
        let rect = try #require(result.bounds)
        #expect(abs(geometry.displaySize.width / geometry.displaySize.height - 16.0 / 9) < 0.001)
        #expect(rect.minY > 0.15 && rect.maxY < 0.85)
    }

    @Test("Reset after stop and seek drops prior analysis")
    @MainActor func engineLifecycle() async throws {
        let engine = try AetherEngine()
        #expect(await engine.sampleActivePicture() == .unknown(.unavailable))
        engine.stopActivePictureAnalysis()
        _ = engine.advanceSeekGeneration()
        #expect(await engine.sampleActivePicture() == .unknown(.unavailable))
        engine.stop()
    }
}
