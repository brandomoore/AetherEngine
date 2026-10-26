import Foundation
import CoreVideo
import VideoToolbox
import AetherLibavutil
import Testing
@testable import AetherEngine

/// AE#354: the software host's VT-backed decoder attached no pixel aspect ratio, so anamorphic HEVC
/// reached the layer at its coded dimensions (measured: 720x576 at 64:45 presented as 720x576, a
/// 16:9 picture squashed into 5:4). The libavcodec decoder on the same host has attached it since
/// #177; the gap was one decoder wide.
///
/// The decision is the same one `SoftwareVideoDecoder` makes, minus the per-frame source: VT hands
/// over pixel buffers, not `AVFrame`s, so only the two declared ratios exist here.
@Suite("VT-backed decoder pixel aspect (#354)")
struct Issue354HardwareDecoderPixelAspectTests {

    private func rational(_ num: Int32, _ den: Int32) -> AVRational {
        AVRational(num: num, den: den)
    }

    @Test("the bitstream ratio wins over the container's")
    func bitstreamWins() {
        let resolved = HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(64, 45), container: rational(1, 1), width: 720, height: 576)

        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    /// The case that keeps the container fallback alive: Matroska writes its DisplayWidth quotient to
    /// the stream and leaves codecpar at 0:1, which is every DVD remuxed to MKV.
    @Test("an unset bitstream ratio falls back to the container's")
    func containerIsTheFallback() {
        let resolved = HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(0, 1), container: rational(64, 45), width: 720, height: 576)

        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    @Test("square pixels attach nothing")
    func squarePixelsAttachNothing() {
        #expect(HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(1, 1), container: rational(1, 1), width: 1920, height: 1080) == nil)
    }

    @Test("a garbage component ratio is rejected (#177)")
    func garbageComponentsRejected() {
        #expect(HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(1088, 1), container: rational(0, 1), width: 1920, height: 1080) == nil)
    }

    /// #290: plausible numbers, impossible picture. 1080p declaring 3:1 smears into a 5.33:1 band.
    @Test("a ratio whose display aspect is impossible is rejected (#290)")
    func impossibleDisplayAspectRejected() {
        #expect(HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(3, 1), container: rational(0, 1), width: 1920, height: 1080) == nil)
    }

    /// The same 2:1 that is wrong on a full-width frame is right on a half-width broadcast one, which
    /// is why the gate needs the frame and not just the numbers.
    @Test("2:1 on a 960x1080 broadcast frame is kept")
    func halfWidthBroadcastKept() {
        let resolved = HardwareVideoDecoder.resolvePixelAspectRatio(
            bitstream: rational(2, 1), container: rational(0, 1), width: 960, height: 1080)

        #expect(resolved?.num == 2)
        #expect(resolved?.den == 1)
    }

    private func makeOutput(width: Int = 16, height: Int = 16,
                            pixelFormat: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as NSDictionary, &buffer)
        #expect(result == kCVReturnSuccess)
        return try #require(buffer)
    }

    private func normalize(_ buffer: CVPixelBuffer, with normalizer: VideoToolboxOutputMetadataNormalizer,
                           modifiable: Bool = false, ratio: AVRational? = nil,
                           primaries: CFString? = nil) -> CVPixelBuffer {
        normalizer.applyingOutputMetadata(to: buffer, isModifiable: modifiable,
            colorPrimaries: primaries, transferFunction: nil, yCbCrMatrix: nil,
            pixelAspectRatio: ratio)
    }

    private func aspect(_ buffer: CVPixelBuffer) -> NSDictionary? {
        CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) as? NSDictionary
    }

    @Test("immutable output is copied before adding display metadata")
    func immutableOutputRetainsItsAttachments() throws {
        let input = try makeOutput()
        let customKey = "test.preserved" as CFString
        CVBufferSetAttachment(input, customKey, "value" as CFString, .shouldPropagate)
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        let output = normalize(input, with: normalizer, ratio: rational(64, 45),
                               primaries: kCVImageBufferColorPrimaries_ITU_R_709_2)
        #expect(output !== input)
        #expect(aspect(input) == nil)
        #expect(CVBufferCopyAttachment(input, kCVImageBufferColorPrimariesKey, nil) == nil)
        #expect(aspect(output)?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int == 64)
        #expect(CVBufferCopyAttachment(output, customKey, nil) as? String == "value")
    }

    @Test("modifiable output gets metadata in place")
    func modifiableOutputIsReused() throws {
        let input = try makeOutput()
        let output = normalize(input, with: VideoToolboxOutputMetadataNormalizer(),
                               modifiable: true, ratio: rational(64, 45))
        #expect(output === input)
        #expect(aspect(input)?[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int == 45)
    }

    @Test("matching metadata needs no copy even on an immutable output")
    func matchingOutputIsReused() throws {
        let input = try makeOutput()
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        _ = normalize(input, with: normalizer, modifiable: true, ratio: rational(64, 45))
        let output = normalize(input, with: normalizer, ratio: rational(64, 45))
        #expect(output === input)
    }

    @Test("a matching but non-propagating attachment is not a match")
    func nonPropagatingMatchIsRewritten() throws {
        let input = try makeOutput()
        let aspectValue: NSDictionary = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 64,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 45,
        ]
        CVBufferSetAttachment(input, kCVImageBufferPixelAspectRatioKey, aspectValue, .shouldNotPropagate)
        CVBufferSetAttachment(input, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldNotPropagate)
        let output = normalize(input, with: VideoToolboxOutputMetadataNormalizer(), ratio: rational(64, 45),
                               primaries: kCVImageBufferColorPrimaries_ITU_R_709_2)
        #expect(output !== input)
        var mode = CVAttachmentMode.shouldNotPropagate
        #expect(CVBufferCopyAttachment(output, kCVImageBufferPixelAspectRatioKey, &mode) != nil)
        #expect(mode == .shouldPropagate)
        mode = .shouldNotPropagate
        #expect(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, &mode) != nil)
        #expect(mode == .shouldPropagate)
    }

    @Test("a stale non-propagating PAR is still removed on square pixels")
    func staleNonPropagatingRatioIsRemoved() throws {
        let input = try makeOutput()
        let aspectValue: NSDictionary = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 4,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 3,
        ]
        CVBufferSetAttachment(input, kCVImageBufferPixelAspectRatioKey, aspectValue, .shouldNotPropagate)
        let output = normalize(input, with: VideoToolboxOutputMetadataNormalizer(), modifiable: true)
        #expect(output === input)
        #expect(aspect(output) == nil)
    }

    @Test("square-pixel output removes stale PAR without mutating an immutable source")
    func staleRatioIsRemovedFromOwnedCopy() throws {
        let input = try makeOutput()
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        _ = normalize(input, with: normalizer, modifiable: true, ratio: rational(64, 45))
        let output = normalize(input, with: normalizer)
        #expect(output !== input)
        #expect(aspect(output) == nil)
        #expect(aspect(input) != nil)
    }

    @Test("owned copies retain pixels and follow format changes")
    func copiedPixelsSurvivePoolReconfiguration() throws {
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        for width in [16, 32, 16] {
            let input = try makeOutput(width: width)
            #expect(CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess)
            let base = try #require(CVPixelBufferGetBaseAddress(input))
            memset(base, 0x59, CVPixelBufferGetDataSize(input))
            CVPixelBufferUnlockBaseAddress(input, [])
            let output = normalize(input, with: normalizer, ratio: rational(64, 45))
            #expect(output !== input)
            #expect(CVPixelBufferGetWidth(output) == width)
            #expect(CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess)
            let copied = try #require(CVPixelBufferGetBaseAddress(output))
            #expect(copied.load(as: UInt8.self) == 0x59)
            CVPixelBufferUnlockBaseAddress(output, .readOnly)
        }
        normalizer.reset()
        let input = try makeOutput()
        #expect(normalize(input, with: normalizer, ratio: rational(64, 45)) !== input)
    }
    @Test("owned copies preserve bi-planar decoder output",
          arguments: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    func biPlanarPixelsArePreserved(pixelFormat: OSType) throws {
        let input = try makeOutput(pixelFormat: pixelFormat)
        #expect(CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess)
        for plane in 0..<CVPixelBufferGetPlaneCount(input) {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(input, plane))
            // 0x8080 is a valid P010 word: its low six padding bits are zero.
            memset(base, 0x80, CVPixelBufferGetHeightOfPlane(input, plane)
                   * CVPixelBufferGetBytesPerRowOfPlane(input, plane))
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        let output = normalize(input, with: VideoToolboxOutputMetadataNormalizer(), ratio: rational(64, 45))
        #expect(output !== input)
        #expect(CVPixelBufferGetPixelFormatType(output) == pixelFormat)
        #expect(CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        for plane in 0..<CVPixelBufferGetPlaneCount(output) {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(output, plane))
            #expect(base.load(as: UInt8.self) == 0x80)
        }
    }

}
