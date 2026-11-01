import Foundation
import Testing
@testable import AetherEngine

/// A DVD-Video image with no ISO9660 bridge volume, only UDF: recognized through UDF instead of falling
/// through to a raw open of the whole image.
@Suite("UDF-only DVD-Video images")
struct UDFOnlyDVDImageTests {

    private static let preparationLimits = ProbeLimits(
        maxInputBytes: 8 * 1024 * 1024, maxPackets: 1024, timeBudget: 3600)

    /// Generated black 16x16/25 fps MPEG-2 templates, no external media:
    /// ffmpeg -f lavfi -i color=c=black:s=16x16:r=25:d=0.48 -c:v mpeg2video -g 12 -bf 0
    ///        -pix_fmt yuv420p -f mpeg2video pipe:1
    /// One picture per PES, PTS 40 ms after DTS, reproduces the DVD timestamp-seek landing.
    /// Padding keeps native seeks outside the AVIO buffer; it is not decoded media.
    private static func preparationProgramStream(keyInterval: Int = 12) -> Data {
        let iFrame = [UInt8](Data(base64Encoded:
            "AAABswEAEBP//+AYAAABtRSKAAEAAAAAAbgACABAAAABAAAP//gAAAG1j//zQYAAAAEBE/h9KUiI")!)
        let pFrame = [UInt8](Data(base64Encoded: "AAABAABX//uAAAABtYEf80GAAAABARJw")!)
        func timestamp(_ ticks: Int64, prefix: UInt8) -> [UInt8] {
            [prefix | UInt8((ticks >> 29) & 0x0E) | 1,
             UInt8((ticks >> 22) & 0xFF), UInt8((ticks >> 14) & 0xFE) | 1,
             UInt8((ticks >> 7) & 0xFF), UInt8((ticks << 1) & 0xFE) | 1]
        }
        var bytes = [UInt8]()
        for frame in 0..<250 {
            let key = frame % keyInterval == 0
            var picture = key ? iFrame : pFrame
            let header = key ? 30 : 0
            let reference = frame % keyInterval
            picture[header + 4] = UInt8(reference >> 2)
            picture[header + 5] = (picture[header + 5] & 0x3F) | UInt8((reference & 3) << 6)
            let scr = Int64(frame * 3_600)
            let pack: [UInt8] = [
                0, 0, 1, 0xBA, 0x44 | UInt8((scr >> 27) & 0x38) | UInt8((scr >> 28) & 3),
                UInt8((scr >> 20) & 0xFF), UInt8((scr >> 12) & 0xF8) | 4 | UInt8((scr >> 13) & 3),
                UInt8((scr >> 5) & 0xFF), UInt8((scr << 3) & 0xF8) | 4, 1, 0, 0x10, 3, 0xF8,
            ]
            let dts = Int64(45_000 + frame * 3_600)
            let payload: [UInt8] = [0x80, 0xC0, 10]
                + timestamp(dts + 3_600, prefix: 0x30) + timestamp(dts, prefix: 0x10) + picture
            let pes: [UInt8] = [0, 0, 1, 0xE0, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
                + payload
            let padding = 2048 - pack.count - pes.count - 6
            bytes += pack + pes + [0, 0, 1, 0xBE, UInt8(padding >> 8), UInt8(padding & 0xFF)]
            bytes += [UInt8](repeating: 0xFF, count: padding)
        }
        return Data(bytes + [0, 0, 1, 0xB9])
    }

    private static func preparationImage(_ programStream: Data) -> Data {
        UDFFixture.makeDVD(files: [
            ("VIDEO_TS.IFO", [UInt8](repeating: 0, count: 2048)),
            ("VTS_01_1.VOB", [UInt8](programStream)),
        ])
    }

    @Test("Only DVD preparation recovers a timestamp seek whose first independent picture is late")
    func preparationRecoversLateDVDLanding() throws {
        let stream = Self.preparationProgramStream()
        let plain = try AetherEngine.prepareSource(
            source: .custom(ProbeRecordingReader(data: stream), formatHint: "mpeg"),
            presentationTime: 3, duration: 4, preroll: 0, limits: Self.preparationLimits)
        #expect(plain.outcome == .endOfSource)
        #expect(try #require(plain.video?.firstSourceTime) > 3.54)
        #expect(try #require(plain.video?.randomAccessSourceTime) > 3.54)

        let reader = ProbeRecordingReader(data: Self.preparationImage(stream), discImageProbeEnabled: true)
        let report = try AetherEngine.prepareSource(
            source: .custom(reader), presentationTime: 3, duration: 4, preroll: 0,
            limits: Self.preparationLimits)
        #expect(report.outcome == .complete)
        #expect(report.selectedDiscTitleID == 0)
        #expect(abs(try #require(report.sourceOrigin) - 0.54) < 0.0001)
        #expect(report.requestedPresentationRange == 3...7)
        #expect(report.requestedSourceRange == 3.54...7.54)
        let video = try #require(report.video)
        #expect(try #require(video.firstSourceTime) < 3.54)
        #expect(try #require(video.randomAccessSourceTime) <= 3.54)
        #expect(try #require(video.observedSourceRange).upperBound >= 7.54)
        #expect(report.demuxedPackets > video.packetCount + 1,
                "the discarded landing and head-origin peek still consume the global packet budget")
        #expect(report.inputBytesRead == reader.bytesRead)
        #expect(reader.closeCount == 0)
    }

    @Test("DVD recovery does not reset the whole-operation packet allowance")
    func preparationRecoveryKeepsPacketBudget() throws {
        let reader = ProbeRecordingReader(
            data: Self.preparationImage(Self.preparationProgramStream()), discImageProbeEnabled: true)
        var limits = Self.preparationLimits
        limits.maxPackets = 32
        let report = try AetherEngine.prepareSource(
            source: .custom(reader), presentationTime: 3, duration: 4, preroll: 0, limits: limits)
        #expect(report.outcome == .budgetExhausted(.packetLimit))
        #expect(report.demuxedPackets == limits.maxPackets)
        let video = try #require(report.video)
        #expect(try #require(video.firstSourceTime) < 3.54)
        #expect(report.demuxedPackets > video.packetCount + 1)
        #expect(report.inputBytesRead == reader.bytesRead)
        #expect(reader.closeCount == 0)
    }

    @Test("A DVD with no independent start in the bounded retry remains incomplete")
    func preparationRetryCannotInventAnEarlierKeyframe() throws {
        let reader = ProbeRecordingReader(
            data: Self.preparationImage(Self.preparationProgramStream(keyInterval: 200)),
            discImageProbeEnabled: true)
        let report = try AetherEngine.prepareSource(
            source: .custom(reader), presentationTime: 3, duration: 4, preroll: 0,
            limits: Self.preparationLimits)
        #expect(report.outcome == .endOfSource)
        #expect(try #require(report.video?.firstSourceTime) < 3.54)
        #expect(try #require(report.video?.randomAccessSourceTime) > 3.54)
        #expect(report.requestedSourceRange == 3.54...7.54)
        #expect(report.inputBytesRead == reader.bytesRead)
        #expect(reader.closeCount == 0)
    }

    @Test("Cancellation on the recovered DVD traversal still throws and leaves the reader owned by its caller")
    func preparationRecoveryCancellation() throws {
        let image = Self.preparationImage(Self.preparationProgramStream())
        let baseline = ProbeRecordingReader(data: image, discImageProbeEnabled: true)
        let complete = try AetherEngine.prepareSource(
            source: .custom(baseline), presentationTime: 3, duration: 4, preroll: 0,
            limits: Self.preparationLimits)
        try #require(complete.outcome == .complete)
        let video = try #require(complete.video)
        try #require(complete.demuxedPackets > video.packetCount + 1)
        let finalSeek = baseline.seeks.count
        try #require(finalSeek > 0)
        let token = ProbeCancellation()
        let box = ProbeTestBox<ProbeRecordingReader?>(nil)
        let reader = ProbeRecordingReader(data: image, discImageProbeEnabled: true, afterSeek: {
            if box.value?.seeks.count == finalSeek { token.cancel() }
        })
        box.update { $0 = reader }
        defer { box.update { $0 = nil } }
        #expect(throws: CancellationError.self) {
            try AetherEngine.prepareSource(
                source: .custom(reader), presentationTime: 3, duration: 4, preroll: 0,
                limits: Self.preparationLimits, cancellation: token)
        }
        #expect(token.isCancelled)
        #expect(reader.closeCount == 0)
    }

    static func bytes(_ seed: UInt8, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &* 37 &+ $0) }
    }

    /// Two title sets; the first one's content is two VOBs. The IFOs are unreadable on purpose: the
    /// title sets then come from the VOB names alone, as on any disc whose VMGI does not parse.
    static func files(contentA: Int = 5000, contentB: Int = 4100) -> [(name: String, bytes: [UInt8])] {
        [("VIDEO_TS.IFO", bytes(1, 2048)),
         ("VIDEO_TS.VOB", bytes(2, 2048)),
         ("VTS_01_0.IFO", bytes(3, 2048)),
         ("VTS_01_0.VOB", bytes(4, 2048)),
         ("VTS_01_1.VOB", bytes(5, contentA)),
         ("VTS_01_2.VOB", bytes(6, contentB)),
         ("VTS_02_1.VOB", bytes(7, 3000))]
    }

    static func readToEnd(_ reader: IOReader) -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1000)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 1000) }
            if n <= 0 { break }
            out += buffer[0..<Int(n)]
        }
        return out
    }

    @Test("the main title set's VOBs play back to back, not the image from its first byte")
    func recognizesTheTitleSets() throws {
        let image = UDFFixture.makeDVD(files: Self.files())
        let reader = DataIOReader(data: image)
        #expect(!DiscReader.looksLikeISO9660(reader))
        let info = try #require(try DiscReader.wrap(reader))
        #expect(info.formatHint == "mpeg")
        #expect(info.titles.count == 2)
        #expect(info.titles.map(\.dvdVTSN) == [1, 2])
        #expect(Self.readToEnd(info.reader) == Self.bytes(5, 5000) + Self.bytes(6, 4100))

        let second = try #require(try DiscReader.wrap(DataIOReader(data: image), selectTitleID: 1))
        #expect(Self.readToEnd(second.reader) == Self.bytes(7, 3000))
    }

    @Test("a file recorded as runs that do not continue each other is left out of the title")
    func fragmentedFileIsLeftOut() throws {
        let image = UDFFixture.makeDVD(files: Self.files(), fragmented: ["VTS_01_2.VOB"])
        let info = try #require(try DiscReader.wrap(DataIOReader(data: image)))
        #expect(Self.readToEnd(info.reader) == Self.bytes(5, 5000))
    }

    @Test("a UDF-only VIDEO_TS with no title VOBs is not a disc")
    func noTitleVOBs() throws {
        let image = UDFFixture.makeDVD(files: [("VIDEO_TS.IFO", Self.bytes(1, 2048)), ("VIDEO_TS.VOB", Self.bytes(2, 2048))])
        #expect(try DiscReader.wrap(DataIOReader(data: image)) == nil)
    }

    @Test("disc-inspect calls it DVD-Video, as playback does")
    func inspectorAgrees() {
        let inspection = DiscInspector.inspect(DataIOReader(data: UDFFixture.makeDVD(files: Self.files())))
        #expect(inspection.kind == .dvdVideo)
        #expect(!inspection.iso9660Signature)
        #expect(inspection.udfAnchor)
        #expect(inspection.dvdVOBFiles.contains("VTS_01_1.VOB"))
        #expect(inspection.wrapRecognized)
        #expect(inspection.wrapFormatHint == "mpeg")
    }

    /// Records where a reader was asked to seek.
    final class SeekLog: IOReader, @unchecked Sendable {
        private let base: DataIOReader
        private let lock = NSLock()
        private var offsets: [Int64] = []
        init(_ data: Data) { base = DataIOReader(data: data) }
        var seeks: [Int64] { lock.withLock { offsets } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { base.read(buffer, size: size) }
        func seek(offset: Int64, whence: Int32) -> Int64 {
            if whence == SEEK_SET { lock.withLock { offsets.append(offset) } }
            return base.seek(offset: offset, whence: whence)
        }
        func close() {}
    }

    @Test("a source that is no disc is still sniffed for the UDF anchor once")
    func nonDiscReadsTheAnchorOnce() throws {
        let reader = SeekLog(Data(repeating: 0, count: 600 * 1024))
        #expect(try DiscReader.wrap(reader) == nil)
        #expect(reader.seeks.filter { $0 == 256 * 2048 }.count == 1)
    }
}
