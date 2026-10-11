import Foundation
import Testing
@testable import AetherEngine

/// #699: HDR Vivid (CUVA T/UWA 005.1) detection in the opt-in probe pass. The fixture is a two-frame
/// 64x64 HEVC/HLG MP4 with a CUVA T.35 SEI that ffprobe reports as "HDR Dynamic Metadata CUVA 005.1
/// 2021 (Vivid)", built by `Scripts/make-hdr10plus-fixture.py --vivid`.
@Suite("HDR Vivid probe detection (#699)")
struct HDRVividProbeTests {

    // MARK: - the body validator

    /// The fixture's CUVA body: one tone-mapping parameter set with base curve and one 3-spline, two
    /// saturation gains, 207 bits and one zero padding bit.
    private static let body: [UInt8] = [
        0x01, 0x00, 0x0B, 0xE6, 0x5F, 0xFF, 0xFF, 0xAB, 0x4A, 0xB3, 0x33, 0x0F, 0xF0,
        0x00, 0x52, 0x88, 0x01, 0x1C, 0x00, 0x00, 0xFF, 0xBF, 0xEF, 0xF4, 0x4C, 0x32,
    ]

    private func complete(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { HDRVividMetadataScan.bodyIsComplete($0) }
    }

    @Test("a complete CUVA body validates, with or without trailing zero bytes")
    func completeBody() {
        #expect(complete(Self.body))
        #expect(complete(Self.body + [0, 0]))
    }

    @Test("a body cut short of its last field is not evidence")
    func truncatedBody() {
        #expect(!complete(Array(Self.body.dropLast())))
    }

    @Test("a set bit after the last field is not evidence")
    func nonZeroPadding() {
        var bytes = Self.body
        bytes[bytes.count - 1] |= 1
        #expect(!complete(bytes))
        #expect(!complete(Self.body + [0x80]))
    }

    @Test("only system_start_code 1 to 7 has a defined syntax")
    func startCodeRange() {
        for code: UInt8 in [0, 8, 0xFF] {
            var bytes = Self.body
            bytes[0] = code
            #expect(!complete(bytes), "start code \(code)")
        }
        var seven = Self.body
        seven[0] = 7
        #expect(complete(seven))
    }

    @Test("a cap keeps what the pass already confirmed, and the default reads as the HDR10+ target")
    func outcomeKeepsPartialFindings() {
        let partial = HDR10PlusDetectionOutcome(
            stopReason: .packetCap, packetsRead: 32, bytesRead: 1000, found: .hdr10Plus)
        #expect(partial.carriesHDR10Plus)
        #expect(!partial.carriesHDRVivid)
        #expect(HDR10PlusDetectionOutcome(stopReason: .found, packetsRead: 1, bytesRead: 1).carriesHDR10Plus)
        #expect(!HDR10PlusDetectionOutcome(stopReason: .found, packetsRead: 1, bytesRead: 1).carriesHDRVivid)
    }

    // MARK: - end to end

    private static func writeFixture(_ base64: String, name: String) throws -> URL {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-hdr-vivid-\(name)-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    @Test("the base probe does not read packets, so it does not report HDR Vivid")
    func baseProbeIsOptIn() throws {
        let url = try Self.writeFixture(Self.vividBase64, name: "base")
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try AetherEngine.probe(url: url)
        #expect(probe.videoFormat == .hlg)
        #expect(!probe.carriesHDRVividMetadata)
    }

    @Test("asking for .hdrVivid finds the CUVA payload and leaves the HLG label alone")
    func detectingFindsVivid() throws {
        let url = try Self.writeFixture(Self.vividBase64, name: "vivid")
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try AetherEngine.probe(url: url, detecting: .hdrVivid)
        #expect(probe.carriesHDRVividMetadata)
        #expect(!probe.carriesHDR10PlusMetadata)
        #expect(probe.videoFormat == .hlg)
    }

    @Test("asking for both reports each format only on the source that carries it")
    func bothTargetsStaySeparate() throws {
        let vivid = try Self.writeFixture(Self.vividBase64, name: "both-vivid")
        let plus = try Self.writeFixture(HDR10PlusProbeIntegrationTests.hdr10PlusBase64, name: "both-plus")
        defer {
            try? FileManager.default.removeItem(at: vivid)
            try? FileManager.default.removeItem(at: plus)
        }
        let vividProbe = try AetherEngine.probe(url: vivid, detecting: [.hdr10Plus, .hdrVivid])
        #expect(vividProbe.carriesHDRVividMetadata)
        #expect(!vividProbe.carriesHDR10PlusMetadata)
        let plusProbe = try AetherEngine.probe(url: plus, detecting: [.hdr10Plus, .hdrVivid])
        #expect(plusProbe.carriesHDR10PlusMetadata)
        #expect(plusProbe.videoFormat == .hdr10Plus)
        #expect(!plusProbe.carriesHDRVividMetadata)
    }

    static let vividBase64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAfm1kYXQAAAAkTgEEHyYABAAFAQAL5l///6tKszMP8ABSiAEc
        AAD/v+/0TDKAAAAADigBr3jrrvv//FtlXy08AAAAJE4BBB8mAAQABQEAC+Zf//+rSrMzD/AAUogBHAAA/7/v9EwygAAAABAoAa8J
        4CQEyH//J2Eew0j8AAADw21vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAADIAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAA
        AAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAALtdHJhawAAAFx0a2hkAAAAAwAA
        AAAAAAAAAAAAAQAAAAAAAADIAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAABAAAAA
        QAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAyAAAAAAAAQAAAAACZW1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAST4AAA6mA
        VcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAAAhBtaW5mAAAAFHZtaGQAAAABAAAAAAAA
        AAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAHQc3RibAAAAWRzdHNkAAAAAAAAAAEAAAFUaHZjMQAAAAAA
        AAABAAAAAAAAAAAAAAAAAAAAAABAAEAASAAAAEgAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAA
        AMdodmNDAQQIAAAAnagAAAAAHvAA/P36+gAADwOgAAIAF0ABDAH//wQIAAADAJ2oAAADAAAeugJAABdAAQwB//8ECAAAAwCdqAAA
        AwAAHroCQKEAAgArQgEBBAgAAAMAnagAAAMAAB6gIIEE2W6kkyvAWoSJBIIAAAMAAgAAAwAUEAArQgEBBAgAAAMAnagAAAMAAB6g
        IIEE2W6kkyvAWoSJBIIAAAMAAgAAAwAUEKIAAgAHRAHBcrAiQAAIRAHBcrAiQAAAAAATY29scm5jbHgACQASAAkAAAAAEHBhc3AA
        AAABAAAAAQAAABRidHJ0AAAAAAAAEnAAABJwAAAAGHN0dHMAAAAAAAAAAQAAAAIAAdTAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAC
        AAAAAQAAABxzdHN6AAAAAAAAAAAAAAACAAAAOgAAADwAAAAUc3RjbwAAAAAAAAABAAAALAAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAA
        IWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAx
        """
}
