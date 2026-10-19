import Testing
@testable import AetherEngine

/// AE#842: `suppressDisplayCriteria` means "AVKit writes", so a host that keeps the panel in its system
/// format (or writes criteria itself) had no correct setting and paid for an AVKit write that never came.
@Suite("Display-criteria owner: resolution and what each owner costs")
struct Issue842DisplayCriteriaOwnerTests {

    private func options(owner: DisplayCriteriaOwner = .engine, suppress: Bool = false) -> LoadOptions {
        var options = LoadOptions()
        options.displayCriteriaOwner = owner
        options.suppressDisplayCriteria = suppress
        return options
    }

    @Test("the default is the engine, and suppressDisplayCriteria keeps meaning AVKit")
    func defaultsAndLegacySpelling() {
        #expect(options().effectiveDisplayCriteriaOwner == .engine)
        #expect(options(suppress: true).effectiveDisplayCriteriaOwner == .avKit)
    }

    @Test("an explicit owner wins over suppressDisplayCriteria")
    func explicitOwnerWins() {
        #expect(options(owner: .host, suppress: true).effectiveDisplayCriteriaOwner == .host)
        #expect(options(owner: .host, suppress: false).effectiveDisplayCriteriaOwner == .host)
        #expect(options(owner: .avKit, suppress: false).effectiveDisplayCriteriaOwner == .avKit)
    }

    @Test("only the engine owner writes, so a host-owned load clears the engine's leftover and applies nothing")
    func hostNeverWrites() {
        let host = options(owner: .host)
        #expect(!host.engineWritesDisplayCriteria)
        #expect(AetherEngine.loadDisplayCriteriaAction(
            engineWritesCriteria: host.engineWritesDisplayCriteria, audioOnlyPath: false) == .clearStale)
        #expect(!RemoteHLSFormatDetection.shouldApplyDisplayCriteria(
            format: .dolbyVision, engineWritesCriteria: host.engineWritesDisplayCriteria))
    }

    @Test("only AVKit's write can land inside the load")
    func onlyAVKitIsInbound() {
        #expect(options(owner: .avKit).awaitsInboundCriteriaWrite)
        #expect(options(suppress: true).awaitsInboundCriteriaWrite)
        #expect(!options(owner: .host).awaitsInboundCriteriaWrite)
        #expect(!options().awaitsInboundCriteriaWrite)
    }

    @Test("a host-owned HDR load takes the brief play-gate budget, not AVKit's second")
    func hostOwnedHDRIsBrief() {
        for format: VideoFormat in [.hdr10, .hdr10Plus, .hlg, .dolbyVision] {
            #expect(AetherEngine.playGateGrace(
                criteriaUnchanged: false,
                criteriaWrittenBeforeLoad: !options(owner: .host).awaitsInboundCriteriaWrite,
                formatKnown: true, effectiveFormat: format) == .brief)
            #expect(AetherEngine.playGateGrace(
                criteriaUnchanged: false,
                criteriaWrittenBeforeLoad: !options(owner: .avKit).awaitsInboundCriteriaWrite,
                formatKnown: true, effectiveFormat: format) == .full)
        }
    }

    @Test("a secondary engine stays a non-writer with no panel readout, whatever owner the host passed")
    func secondaryStaysSuppressed() {
        var proposed = options(owner: .host)
        proposed.sharedOutputRole = .secondary
        let adjusted = AetherEngine.applyingSharedOutputRole(proposed)
        #expect(adjusted.effectiveDisplayCriteriaOwner == .avKit)
        #expect(!adjusted.engineWritesDisplayCriteria)
    }
}
