import AVFoundation

/// The buffer is borrowed read-only and released after one bounded worker call.
struct ActivePictureFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let time: Double
    let generation: UInt64
}

struct ActivePictureGeometry: Sendable, Equatable {
    let codedSize: CGSize
    let cleanRect: CGRect
    let displaySize: CGSize
    let format: OSType
    let transfer: String?
}

struct ActivePicturePixels: Sendable {
    let geometry: ActivePictureGeometry?
    let bounds: CGRect?
    let failure: ActivePictureState.UnknownReason?
}

actor ActivePictureWorker {
    static let shared = ActivePictureWorker()

    func analyze(_ frame: ActivePictureFrame) -> ActivePicturePixels {
        Self.sample(frame.buffer)
    }

    nonisolated static func sample(_ buffer: CVPixelBuffer) -> ActivePicturePixels {
        func failed(_ reason: ActivePictureState.UnknownReason) -> ActivePicturePixels {
            ActivePicturePixels(geometry: nil, bounds: nil, failure: reason)
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let yuv = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard yuv || format == kCVPixelFormatType_32BGRA else { return failed(.unsupportedColor) }
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        if let transfer, ![
            kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            kCVImageBufferTransferFunction_sRGB as String,
            kCVImageBufferTransferFunction_SMPTE_240M_1995 as String
        ].contains(transfer) {
            return failed(.unsupportedColor)
        }
        let coded = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let clean = CVImageBufferGetCleanRect(buffer)
        let display = CVImageBufferGetDisplaySize(buffer)
        guard clean.minX.isFinite, clean.minY.isFinite, clean.width.isFinite, clean.height.isFinite,
              clean.width >= 8, clean.height >= 8,
              CGRect(origin: .zero, size: coded).contains(clean),
              display.width.isFinite, display.height.isFinite, display.width > 0, display.height > 0
        else { return failed(.unsupportedGeometry) }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return failed(.unavailable) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = yuv ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        else { return failed(.unavailable) }
        let stride = yuv ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let w = min(320, Int(clean.width)), h = min(180, Int(clean.height))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let py = Int(coded.height - clean.maxY + (Double(y) + 0.5) * clean.height / Double(h))
            for x in 0..<w {
                let px = Int(clean.minX + (Double(x) + 0.5) * clean.width / Double(w))
                let value: Int
                if yuv {
                    let raw = Int(bytes[py * stride + px])
                    value = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                        ? max(0, min(255, (raw - 16) * 255 / 219)) : raw
                } else {
                    let i = py * stride + px * 4
                    value = (Int(bytes[i]) * 19 + Int(bytes[i + 1]) * 183 + Int(bytes[i + 2]) * 54) / 256
                }
                luma[y * w + x] = UInt8(value)
            }
        }
        return ActivePicturePixels(
            geometry: ActivePictureGeometry(codedSize: coded, cleanRect: clean, displaySize: display,
                                            format: format, transfer: transfer),
            bounds: ActivePictureDetector.bounds(luma: luma, width: w, height: h), failure: nil
        )
    }
}
