import AVFoundation

/// The buffer is borrowed read-only and released after one bounded worker call.
struct ActivePictureFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let time: Double
    let generation: UInt64
    let displaySize: CGSize?

    init(buffer: CVPixelBuffer, time: Double, generation: UInt64, displaySize: CGSize? = nil) {
        self.buffer = buffer
        self.time = time
        self.generation = generation
        self.displaySize = displaySize
    }
}

struct ActivePictureGeometry: Sendable, Equatable {
    let codedSize: CGSize
    let cleanRect: CGRect
    let displaySize: CGSize
    let format: OSType
    let transfer: String?

    static func supports(_ transform: CGAffineTransform) -> Bool {
        [transform.a, transform.b, transform.c, transform.d].allSatisfy { $0 == 0 || abs($0) == 1 }
            && abs(transform.a * transform.d - transform.b * transform.c) == 1
            && transform.a * transform.c + transform.b * transform.d == 0
    }

    func upright(_ rect: CGRect, transform: CGAffineTransform) -> (rect: CGRect, size: CGSize) {
        let canvas = CGRect(origin: .zero, size: displaySize)
        let upright = canvas.applying(transform)
        let picture = CGRect(
            x: rect.minX * canvas.width, y: rect.minY * canvas.height,
            width: rect.width * canvas.width, height: rect.height * canvas.height
        )
        .applying(transform)
        return (
            CGRect(
                x: (picture.minX - upright.minX) / upright.width,
                y: (picture.minY - upright.minY) / upright.height,
                width: picture.width / upright.width, height: picture.height / upright.height), upright.size
        )
    }
}

struct ActivePicturePixels: Sendable {
    let geometry: ActivePictureGeometry?
    let bounds: CGRect?
    let failure: ActivePictureState.UnknownReason?
}

actor ActivePictureWorker {
    static let shared = ActivePictureWorker()

    func analyze(_ frame: ActivePictureFrame) -> ActivePicturePixels {
        Self.sample(frame.buffer, displaySize: frame.displaySize)
    }

    nonisolated static func sample(_ buffer: CVPixelBuffer, displaySize: CGSize? = nil) -> ActivePicturePixels {
        func failed(_ reason: ActivePictureState.UnknownReason) -> ActivePicturePixels {
            ActivePicturePixels(geometry: nil, bounds: nil, failure: reason)
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit =
            format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let yuv =
            tenBit || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let halfFloat = format == kCVPixelFormatType_64RGBAHalf
        guard yuv || halfFloat || format == kCVPixelFormatType_32BGRA else {
            return failed(.unsupportedColor)
        }
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let hdr =
            transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
            || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        let linear = transfer == kCVImageBufferTransferFunction_Linear as String
        if let transfer,
            ![
                kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                kCVImageBufferTransferFunction_sRGB as String,
                kCVImageBufferTransferFunction_SMPTE_240M_1995 as String,
                kCVImageBufferTransferFunction_ITU_R_2020 as String,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
                kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                kCVImageBufferTransferFunction_Linear as String,
            ].contains(transfer)
        {
            return failed(.unsupportedColor)
        }
        guard !linear || halfFloat else { return failed(.unsupportedColor) }
        let coded = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let clean = CVImageBufferGetCleanRect(buffer)
        let display = displaySize ?? CVImageBufferGetDisplaySize(buffer)
        guard clean.minX.isFinite, clean.minY.isFinite, clean.width.isFinite, clean.height.isFinite,
            clean.width >= 8, clean.height >= 8,
            CGRect(origin: .zero, size: coded).contains(clean),
            display.width.isFinite, display.height.isFinite, display.width > 0, display.height > 0
        else { return failed(.unsupportedGeometry) }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return failed(.unavailable)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard
            let base = yuv
                ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        else { return failed(.unavailable) }
        let stride =
            yuv ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let w = min(320, Int(clean.width))
        let h = min(180, Int(clean.height))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let py = Int(coded.height - clean.maxY + (Double(y) + 0.5) * clean.height / Double(h))
            for x in 0..<w {
                let px = Int(clean.minX + (Double(x) + 0.5) * clean.width / Double(w))
                let value: Int
                if tenBit {
                    let row = base.advanced(by: py * stride).assumingMemoryBound(to: UInt16.self)
                    let raw = Int(row[px] >> 6)
                    value =
                        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                        ? max(0, min(255, (raw - 64) * 255 / 876)) : raw * 255 / 1023
                } else if yuv {
                    let raw = Int(bytes[py * stride + px])
                    value =
                        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                        ? max(0, min(255, (raw - 16) * 255 / 219)) : raw
                } else if halfFloat {
                    let row = base.advanced(by: py * stride).assumingMemoryBound(to: UInt16.self)
                    let red = Float(Float16(bitPattern: row[px * 4]))
                    let green = Float(Float16(bitPattern: row[px * 4 + 1]))
                    let blue = Float(Float16(bitPattern: row[px * 4 + 2]))
                    guard red.isFinite, green.isFinite, blue.isFinite else {
                        return failed(.unsupportedColor)
                    }
                    let peak = max(0, min(1, max(red, green, blue)))
                    value = Int((linear ? sqrt(peak) : peak) * 255)
                } else {
                    let i = py * stride + px * 4
                    value = (Int(bytes[i]) * 19 + Int(bytes[i + 1]) * 183 + Int(bytes[i + 2]) * 54) / 256
                }
                luma[y * w + x] = UInt8(value)
            }
        }
        return ActivePicturePixels(
            geometry: ActivePictureGeometry(
                codedSize: coded, cleanRect: clean, displaySize: display,
                format: format, transfer: transfer),
            // HDR near-black codes are not interchangeable with SDR. Keep
            // their threshold close to reference black, including raised bars.
            bounds: ActivePictureDetector.bounds(
                luma: luma, width: w, height: h,
                blackThreshold: hdr || linear ? 2 : 8), failure: nil
        )
    }
}
