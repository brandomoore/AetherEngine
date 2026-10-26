import Combine
import Foundation
import Testing
@testable import AetherEngine

/// `AetherEngine.isClockHeld` / `clockHoldEvents` (#800): the software host's clock hold, published per
/// engine so a host does not read the held clock as a stall.
@Suite("Clock hold publication")
@MainActor
struct ClockHoldEventTests {

    private func transition(_ generation: Int, _ event: ClockHoldEvent) -> AudioOutput.PrerollTransition {
        AudioOutput.PrerollTransition(generation: generation, event: event)
    }

    @Test("A hold and its release publish the level and one event each")
    func holdAndRelease() throws {
        let engine = try AetherEngine()
        var events: [ClockHoldEvent] = []
        let sink = engine.clockHoldEvents.sink { events.append($0) }
        defer { sink.cancel() }
        engine.applyClockHoldTransition(transition(0, .began))
        #expect(engine.isClockHeld)
        engine.applyClockHoldTransition(transition(0, .released(.ready(waitedSeconds: 0.8))))
        #expect(!engine.isClockHeld)
        #expect(events == [.began, .released(.ready(waitedSeconds: 0.8))])
    }

    @Test("A report that arrives behind a newer one is dropped")
    func staleReportsAreDropped() throws {
        let engine = try AetherEngine()
        var events: [ClockHoldEvent] = []
        let sink = engine.clockHoldEvents.sink { events.append($0) }
        defer { sink.cancel() }
        engine.applyClockHoldTransition(transition(3, .began))
        engine.applyClockHoldTransition(transition(2, .released(.cancelled)))
        #expect(engine.isClockHeld, "an older hold's release does not end the current one")
        engine.applyClockHoldTransition(transition(4, .released(.timedOut(waitedSeconds: 2))))
        engine.applyClockHoldTransition(transition(4, .began))
        #expect(!engine.isClockHeld, "a begin that lost the race to its own release stays dropped")
        #expect(events == [.began, .released(.timedOut(waitedSeconds: 2))])
    }

    @Test("The end of a session releases a hold the host can no longer report")
    func sessionEndReleases() throws {
        let engine = try AetherEngine()
        var events: [ClockHoldEvent] = []
        let sink = engine.clockHoldEvents.sink { events.append($0) }
        defer { sink.cancel() }
        engine.applyClockHoldTransition(transition(7, .began))
        engine.endClockHold()
        #expect(!engine.isClockHeld)
        engine.applyClockHoldTransition(transition(0, .began))
        #expect(engine.isClockHeld, "the next session's generations start over")
        #expect(events == [.began, .released(.cancelled), .began])
    }
}
