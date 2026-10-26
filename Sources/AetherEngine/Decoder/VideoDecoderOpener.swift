import Foundation
import CoreMedia
import AetherLibavformat

/// Opens a preferred decoder and atomically falls back before the demux loop captures its pipeline.
enum VideoDecoderOpener {
    struct Result {
        let decoder: any VideoDecodingPipeline
        let preferredFailureDescription: String?

        var usedFallback: Bool { preferredFailureDescription != nil }
    }

    static func openPreferredOrFallback(
        preferred: any VideoDecodingPipeline,
        makeFallback: () -> any VideoDecodingPipeline,
        stream: UnsafeMutablePointer<AVStream>,
        onFrame: @escaping DecodedFrameHandler
    ) throws -> Result {
        do {
            try preferred.open(stream: stream, onFrame: onFrame)
            return Result(decoder: preferred, preferredFailureDescription: nil)
        } catch {
            preferred.close()
            let preferredFailureDescription = error.localizedDescription
            let fallback = makeFallback()
            do {
                try fallback.open(stream: stream, onFrame: onFrame)
                return Result(
                    decoder: fallback,
                    preferredFailureDescription: preferredFailureDescription
                )
            } catch let fallbackError {
                fallback.close()
                throw fallbackError
            }
        }
    }
}
