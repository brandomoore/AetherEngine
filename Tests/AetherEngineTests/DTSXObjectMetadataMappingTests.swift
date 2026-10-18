// Only with the DTSXObjectAudio trait (off by default): the decoder and its library are not built without it.
#if DTSXObjectAudio
import Testing
import Foundation
import DTSX
@testable import AetherEngine

/// LibDTSX returns DTS:X's standard presentation only, and `DTSXObjectAudioDecoder` names its
/// channels. These pin what a listener would hear wrong: a bed or height channel on the wrong
/// speaker, or a channel outside the twelve slipping through to be panned.
@Suite("DTS:X channels map onto the renderer's speakers")
struct DTSXObjectMetadataMappingTests {

    @Test("bed and height speaker codes route to the matching speaker, LFE to LFE, nothing else is taken")
    func speakerRoles() {
        // The standard DTS:X presentation: a 7.1 bed and the top front and top back pairs.
        let standard: [(UInt8, ObjectAudioRole)] = [
            (DTSX_SPEAKER_C, .bed(.center)), (DTSX_SPEAKER_L, .bed(.left)), (DTSX_SPEAKER_R, .bed(.right)),
            (DTSX_SPEAKER_LS, .bed(.sideLeft)), (DTSX_SPEAKER_RS, .bed(.sideRight)), (DTSX_SPEAKER_LFE, .lfe),
            (DTSX_SPEAKER_LB, .bed(.rearLeft)), (DTSX_SPEAKER_RB, .bed(.rearRight)),
            (DTSX_SPEAKER_TFL, .bed(.topFrontLeft)), (DTSX_SPEAKER_TFR, .bed(.topFrontRight)),
            (DTSX_SPEAKER_TBL, .bed(.topRearLeft)), (DTSX_SPEAKER_TBR, .bed(.topRearRight)),
        ]
        for (code, role) in standard {
            #expect(DTSXObjectAudioDecoder.role(forSpeaker: code) == role, "speaker \(code)")
        }
        for code in [DTSX_SPEAKER_OBJECT, DTSX_SPEAKER_UNKNOWN, DTSX_SPEAKER_LW, DTSX_SPEAKER_TSR,
                     DTSX_SPEAKER_TFC, DTSX_SPEAKER_CB, DTSX_SPEAKER_LFE2] {
            #expect(DTSXObjectAudioDecoder.role(forSpeaker: code) == nil, "speaker \(code)")
        }
    }

    @Test("the standard channels play one to one on 7.1.4 and 9.1.6, and only there")
    func oneToOneLayouts() {
        for layout in SpatialSpeakerLayout.allCases {
            #expect(layout.carriesDTSXOneToOne == (layout == .l714 || layout == .l916), "\(layout.rawValue)")
        }
    }

    @Test("a channel plays at unity while active")
    func channelState() {
        var element = DTSXElement()
        element.kind = DTSX_ELEMENT_BED
        element.speaker = DTSX_SPEAKER_TFL
        element.flags = DTSX_ELEMENT_ACTIVE
        element.position = (0, 0, 1)
        element.gain = 1
        let state = DTSXObjectAudioDecoder.state(for: element)
        #expect(state.position == SIMD3(0, 0, 1))
        #expect(state.gain == 1)
        element.flags = 0
        #expect(DTSXObjectAudioDecoder.state(for: element).gain == 0)
    }

    @Test("the decoder opens, takes input and asks for more")
    func decoderLifecycle() throws {
        let decoder = try DTSXObjectAudioDecoder()
        try [UInt8](repeating: 0, count: 64).withUnsafeBytes { try decoder.push($0) }
        #expect(try decoder.nextBlock() == nil)
        decoder.reset()
        #expect(decoder.selfResetCount == 0)
    }

    @Test("input with no DTS frame in it is refused, and the verdict says so")
    func verdictRefusesNonDTS() throws {
        let decoder = try DTSXObjectAudioDecoder()
        let garbage = [UInt8](repeating: 0x55, count: 1 << 20 | 4096)
        let verdict = garbage.withUnsafeBytes { decoder.verdict(feeding: $0) }
        guard case .refused(let reason) = verdict else {
            Issue.record("expected a refusal, got \(String(describing: verdict))")
            return
        }
        #expect(reason.contains("no DTS frame"))
        // The refusal sticks, so a bridge built on it anyway would fail rather than play nothing.
        #expect(throws: DTSXObjectAudioDecoder.DecoderError.self) { try decoder.nextBlock() }
    }
}
#endif
