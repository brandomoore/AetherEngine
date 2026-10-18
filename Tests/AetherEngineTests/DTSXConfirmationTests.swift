import Testing
import Foundation
@testable import AetherEngine

@Suite("DTS:X track flag: profile label and LibDTSX ledger")
struct DTSXConfirmationTests {

    private func dts(id: Int, profile: String?, codec: String = "dca") -> TrackInfo {
        TrackInfo(id: id, name: "Track \(id) (\(codec))", codec: codec, language: nil, channels: 8,
                  isDefault: id == 1, profile: profile)
    }

    @Test("libavcodec's DTS:X profiles mark the track from the probe on")
    func profileLabel() {
        #expect(dts(id: 1, profile: "DTS-HD MA + DTS:X").isDTSX)
        #expect(dts(id: 1, profile: "DTS-HD MA + DTS:X IMAX").isDTSX)
        #expect(dts(id: 1, profile: "DTS-HD MA + DTS:X", codec: "dts").isDTSX)
        #expect(!dts(id: 1, profile: "DTS-HD MA").isDTSX)
        #expect(!dts(id: 1, profile: nil).isDTSX)
        #expect(!dts(id: 1, profile: "DTS:X", codec: "truehd").isDTSX)
    }

    @Test("a confirmed stream index flips its track, the others stay as they were")
    func ledgerFlipsConfirmedOnly() {
        let tracks = [dts(id: 1, profile: "DTS-HD MA"), dts(id: 2, profile: "DTS-HD MA"),
                      dts(id: 3, profile: "DTS-HD MA + DTS:X")]
        let out = AetherEngine.applyingConfirmedDTSX(to: tracks, confirmed: [1])
        #expect(out.map(\.isDTSX) == [true, false, true])
        #expect(out[0].profile == "DTS-HD MA")
    }

    @Test("an empty ledger hands the list back untouched")
    func emptyLedger() {
        let tracks = [dts(id: 1, profile: "DTS-HD MA")]
        #expect(AetherEngine.applyingConfirmedDTSX(to: tracks, confirmed: []) == tracks)
    }
}
