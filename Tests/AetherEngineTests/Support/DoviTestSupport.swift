import Foundation
import CoreVideo

/// Helpers shared by the Dolby Vision composer tests.
enum DoviTestSupport {

    /// `media/` next to the package checkout, where local test titles live (git-ignored; tests that
    /// need one skip when it is absent).
    static var mediaDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("media")
    }

    /// Raw planes from a `.debugRawVDR` compose: 12-bit VDR codes, Cb and Cr de-interleaved.
    static func rawVDR(_ b: CVPixelBuffer, chromaOnly: Bool = false) -> [[Int]] {
        CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        var out = [[Int]]()
        let w = CVPixelBufferGetWidthOfPlane(b, 0), h = CVPixelBufferGetHeightOfPlane(b, 0)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0) / 2
        let yb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt16.self)
        out.append(chromaOnly ? [] : (0..<(w * h)).map { Int(yb[($0 / w) * ys + $0 % w] >> 4) })
        let cw = CVPixelBufferGetWidthOfPlane(b, 1), ch = CVPixelBufferGetHeightOfPlane(b, 1)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1) / 2
        let cb = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt16.self)
        for c in 0..<2 { out.append((0..<(cw * ch)).map { Int(cb[($0 / cw) * cs + ($0 % cw) * 2 + c] >> 4) }) }
        return out
    }
}
