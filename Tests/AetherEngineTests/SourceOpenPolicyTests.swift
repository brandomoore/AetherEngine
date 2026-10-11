import Foundation
import Testing
@testable import AetherEngine

struct SourceOpenPolicyTests {
    @Test func invalidBudgetsUseDefaults() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0] {
            #expect(SourceOpenPolicy(firstByteTimeout: value, sizeProbeTimeout: value) == .init())
        }
        #expect(SourceOpenPolicy(firstByteTimeout: 999, sizeProbeTimeout: 999)
            == .init(firstByteTimeout: 120, sizeProbeTimeout: 120))
    }

    @Test func policiesSurviveProfileCopiesAndReopens() {
        let policy = SourceOpenPolicy(firstByteTimeout: 5, sizeProbeTimeout: 8)
        let options = LoadOptions(sourceOpenPolicy: policy)
        #expect(options.sourceOpenPolicy == policy)
        let profile = DemuxerOpenProfile.playback.withSourceOpenPolicy(policy)
            .withHeldSourceConnection(true).withProbeBudget(probesize: 100, maxAnalyzeDuration: 100)
        #expect(profile.sourceOpenPolicy == policy)
    }
}
