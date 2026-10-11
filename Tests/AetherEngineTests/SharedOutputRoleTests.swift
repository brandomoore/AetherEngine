import Testing
@testable import AetherEngine

/// Sodalite#175: a multiview tile runs beside the engine that owns the panel and Now Playing.
@Suite("Shared output role (Sodalite#175)")
struct SharedOutputRoleTests {

    @Test("the default role is primary, so a single-instance host is untouched")
    func defaultIsPrimary() {
        #expect(LoadOptions().sharedOutputRole == .primary)
    }

    @Test("a secondary load never writes display criteria")
    func secondarySuppressesCriteria() {
        var options = LoadOptions()
        options.sharedOutputRole = .secondary
        #expect(AetherEngine.applyingSharedOutputRole(options).suppressDisplayCriteria)
    }

    @Test("a primary load keeps whatever the host asked for")
    func primaryKeepsHostChoice() {
        #expect(!AetherEngine.applyingSharedOutputRole(LoadOptions()).suppressDisplayCriteria)
        #expect(AetherEngine.applyingSharedOutputRole(LoadOptions(suppressDisplayCriteria: true)).suppressDisplayCriteria)
    }

    @Test("only a primary may own Now Playing, and only when the host opted in")
    func nowPlayingOwnership() {
        #expect(AetherEngine.ownsNowPlaying(hostOptIn: true, role: .primary))
        #expect(!AetherEngine.ownsNowPlaying(hostOptIn: true, role: .secondary))
        #expect(!AetherEngine.ownsNowPlaying(hostOptIn: false, role: .primary))
    }

    @Test("the role names the session, so a correction may not flip it")
    func roleIsIdentity() {
        #expect(SessionOptionCorrection.loadIdentityFields.contains("sharedOutputRole"))
    }
}
