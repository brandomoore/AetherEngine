import Testing
@testable import AetherEngine

@Suite("AE#348: the pre-flight gate runs beside a VOD load")
struct Issue348PreflightBesideLoadTests {

    @Test("A VOD load produces segments while the panel switches")
    func vodOverlaps() {
        #expect(AetherEngine.preflightGateRunsBesideLoad(isLive: false))
    }

    @Test("A live load keeps the gate in front of the load")
    func liveStaysSerial() {
        #expect(!AetherEngine.preflightGateRunsBesideLoad(isLive: true))
    }
}
