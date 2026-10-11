import Testing
import Foundation
@testable import AetherEngine

@Suite("Engine wiring to the shared output coordinator (Sodalite#175)")
@MainActor
struct SharedOutputEngineWiringTests {

    @Test("only the last engine out, with a release owed, deactivates the session")
    func deactivationFollowsOnlyLastOut() {
        #expect(AetherEngine.shouldDeactivateAudioSession(after: .lastOut(releaseSession: true)))
        #expect(!AetherEngine.shouldDeactivateAudioSession(after: .lastOut(releaseSession: false)))
        #expect(!AetherEngine.shouldDeactivateAudioSession(after: .othersRemain(1)))
        #expect(!AetherEngine.shouldDeactivateAudioSession(after: .notMember))
    }

    @Test("a release scheduled by the last engine drops when another engine joined meanwhile")
    func pendingReleaseDropsWhenSomeoneJoined() async {
        let c = SharedOutputCoordinator()
        final class Token {}
        let tokenA = Token(), tokenB = Token()
        let a = ObjectIdentifier(tokenA), b = ObjectIdentifier(tokenB)
        c.join(a, role: .primary, tag: nil)
        let outcome = c.leave(a, releasesSession: true)
        #expect(outcome == .lastOut(releaseSession: true))
        c.join(b, role: .secondary, tag: "tile2")
        #expect(!AetherEngine.releaseStillWanted(coordinatorIsEmpty: c.isEmpty))
    }

    @Test("an engine's log tag is the host's")
    func logTagIsHostSet() throws {
        let engine = try AetherEngine()
        engine.logTag = "tile2"
        #expect(engine.logTag == "tile2")
    }
}
