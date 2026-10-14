import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// AE#735: `load(.formatDescriptions)` runs on the caller's actor, and the first audio description in a
/// process loads the audio DSP stack through dyld (3.8 s on an Apple TV 4K). The native host's track reads
/// are main-actor code, so they go through a helper that runs the load off it; it must still resolve.
@Suite struct Issue735FormatDescriptionsOffMainTests {

    @Test @MainActor func trackFormatDescriptionsStillResolve() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae735-\(UUID().uuidString).wav")
        try Self.silentWAV(channels: 2, sampleRate: 48_000, frames: 4_800).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let description = try #require(await NativeAVPlayerHost.formatDescriptions(of: track).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
        #expect(asbd.mChannelsPerFrame == 2)
        #expect(asbd.mSampleRate == 48_000)
    }

    @Test func aFailedLoadYieldsNil() async {
        struct Refused: Error {}
        let value: Int? = await NativeAVPlayerHost.loadOffMainActor { throw Refused() }
        #expect(value == nil)
    }

    private static func silentWAV(channels: UInt16, sampleRate: UInt32, frames: UInt32) -> Data {
        let blockAlign = channels * 2
        let dataSize = frames * UInt32(blockAlign)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1))
        append(channels); append(sampleRate); append(sampleRate * UInt32(blockAlign)); append(blockAlign); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
