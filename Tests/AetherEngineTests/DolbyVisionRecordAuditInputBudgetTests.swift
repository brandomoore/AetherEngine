import Foundation
import Testing
@testable import AetherEngine

/// Audit BIT-103: the RPU walk bounded packets and the bytes of the packets it was handed, but not the
/// bytes libavformat consumes inside one `av_read_frame`. Matroska resyncs byte by byte through data no
/// element starts in, so a video stream followed by junk read the whole source before the walk got to
/// count anything. The fixture is that shape: two HEVC frames, then zeros.
@Suite("DV record audit: the RPU walk holds an input byte budget below the demuxer")
struct DolbyVisionRecordAuditInputBudgetTests {

    private static let junkBytes = 24 * 1024 * 1024
    private static let budget: Int64 = 1 << 20

    private final class CountingReader: IOReader, @unchecked Sendable {
        private let base: FileIOReader
        private let lock = NSLock()
        private var total: Int64 = 0

        init(_ base: FileIOReader) { self.base = base }

        var bytesRead: Int64 { lock.lock(); defer { lock.unlock() }; return total }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            let n = base.read(buffer, size: size)
            if n > 0 { lock.lock(); total += Int64(n); lock.unlock() }
            return n
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { base.seek(offset: offset, whence: whence) }
        func close() { base.close() }
        var discImageProbeEnabled: Bool { false }
    }

    private func open(_ demuxer: Demuxer, _ url: URL, reader: CountingReader?) throws {
        let profile = DemuxerOpenProfile.dolbyVisionRecordAuditDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil)
        if let reader {
            try demuxer.open(reader: reader, profile: profile)
        } else {
            try demuxer.open(url: url, profile: profile)
        }
    }

    @Test("selective MEL inspection refuses a parser interrupted by the input ceiling")
    func selectiveMELInputCapFailsPreparation() throws {
        let data = try TailHeavyMatroska.make(foreignBytes: Self.junkBytes, junkTail: true)
        try ProbeTestFixtures.withFile(data) { url in
            let reader = CountingReader(try #require(FileIOReader(url: url)))
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try open(demuxer, url, reader: reader)
            let atOpen = reader.bytesRead
            #expect(throws: DolbyVisionRecordAudit.EnhancementLayerInspectionError.inputBudgetExhausted) {
                try DolbyVisionRecordAudit.peekEnhancementLayerType(
                    demuxer: demuxer, streamIndex: demuxer.videoStreamIndex, byteBudget: Self.budget)
            }
            #expect(reader.bytesRead - atOpen <= Self.budget)
        }
    }

    @Test("a junk tail stops the walk at its byte budget on a custom reader")
    func junkTailStopsOnTheBudgetOnACustomReader() throws {
        let data = try TailHeavyMatroska.make(foreignBytes: Self.junkBytes, junkTail: true)
        try ProbeTestFixtures.withFile(data) { url in
            let reader = CountingReader(try #require(FileIOReader(url: url)))
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try open(demuxer, url, reader: reader)
            let atOpen = reader.bytesRead
            #expect(DolbyVisionRecordAudit.rpuProfile(walking: demuxer, byteBudget: Self.budget) == nil)
            #expect(demuxer.inputByteBudgetExhausted)
            #expect(reader.bytesRead - atOpen <= Self.budget)
        }
    }

    @Test("a junk tail stops the walk at its byte budget on a local file")
    func junkTailStopsOnTheBudgetOnALocalFile() throws {
        let data = try TailHeavyMatroska.make(foreignBytes: Self.junkBytes, junkTail: true)
        try ProbeTestFixtures.withFile(data) { url in
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try open(demuxer, url, reader: nil)
            #expect(DolbyVisionRecordAudit.rpuProfile(walking: demuxer, byteBudget: Self.budget) == nil)
            #expect(demuxer.inputByteBudgetExhausted)
        }
    }

    @Test("a budget that covers the file reaches its end, so the cap is the budget and not the fixture")
    func coveringBudgetReadsToTheEnd() throws {
        let data = try TailHeavyMatroska.make(foreignBytes: Self.junkBytes, junkTail: true)
        try ProbeTestFixtures.withFile(data) { url in
            let reader = CountingReader(try #require(FileIOReader(url: url)))
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try open(demuxer, url, reader: reader)
            let atOpen = reader.bytesRead
            #expect(DolbyVisionRecordAudit.rpuProfile(walking: demuxer, byteBudget: Int64(data.count) * 2) == nil)
            #expect(!demuxer.inputByteBudgetExhausted)
            #expect(reader.bytesRead - atOpen > Self.budget)
        }
    }
}
