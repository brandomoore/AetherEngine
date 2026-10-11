// Tests/AetherEngineTests/Issue687RetentionClaimsTests.swift
// #687: every session sized its retention from the raw free space, so sessions started together each
// took a quarter of the same space. A claim is now sized from what the other running claims leave.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Retention claims across concurrent sessions")
struct Issue687RetentionClaimsTests {

    private func session(_ ledger: RetentionClaims, free: Int64?) -> RetentionClaims.Claim {
        ledger.claim(volumeAvailableBytes: free) {
            HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: $0)
        }
    }

    @Test("A session alone gets what it always got")
    func aloneIsUnchanged() {
        let ledger = RetentionClaims()
        let claim = session(ledger, free: 4 << 30)
        #expect(claim.bytes == 1 << 30)
        #expect(claim.heldBackBytes == 0)
    }

    @Test("Four sessions on a tight volume no longer claim all of it")
    func fourSessionsLeaveTheVolumeRoom() {
        let ledger = RetentionClaims()
        let free: Int64 = 4 << 30
        let claims = (0..<4).map { _ in session(ledger, free: free) }
        let total = claims.reduce(0) { $0 + $1.bytes }
        #expect(claims[0].bytes == 1 << 30)
        #expect(claims[1].bytes == (3 << 30) / 4)
        #expect(Double(total) / Double(free) < 0.69)
        #expect(claims.allSatisfy { $0.bytes > 0 })
    }

    @Test("A roomy volume still gives every session the cap")
    func roomyVolumeKeepsTheCap() {
        let ledger = RetentionClaims()
        let claims = (0..<4).map { _ in session(ledger, free: 32 << 30) }
        #expect(claims.allSatisfy { $0.bytes == 2 << 30 })
    }

    @Test("What a session has written is not held back twice")
    func writtenBytesAreNotHeldBack() {
        let ledger = RetentionClaims()
        let first = session(ledger, free: 4 << 30)
        first.track { 1 << 30 }
        // The first session's GiB is on disk, so the measurement already misses it.
        let second = session(ledger, free: 3 << 30)
        #expect(second.heldBackBytes == 0)
        #expect(second.bytes == (3 << 30) / 4)
    }

    @Test("A released claim frees its share, and a dropped one does too")
    func releaseFreesTheShare() {
        let ledger = RetentionClaims()
        let first = session(ledger, free: 4 << 30)
        first.release()
        first.release()
        #expect(session(ledger, free: 4 << 30).bytes == 1 << 30)
        #expect(session(ledger, free: 4 << 30).bytes == 1 << 30)
    }

    @Test("Unknown capacity stays unknown and keeps the cap")
    func unknownCapacityKeepsTheCap() {
        let ledger = RetentionClaims()
        let first = session(ledger, free: nil)
        let second = session(ledger, free: nil)
        #expect(first.bytes == 2 << 30)
        #expect(second.bytes == 2 << 30)
    }

    @Test("The software live ring keeps its floor when others hold everything back")
    func liveRingKeepsItsFloor() {
        let ledger = RetentionClaims()
        let first = session(ledger, free: 1 << 30)
        let ring = ledger.claim(volumeAvailableBytes: Int64(first.bytes) / 2) {
            PacketRingBuffer.liveByteBudget(volumeAvailableBytes: $0)
        }
        #expect(ring.bytes == PacketRingBuffer.minimumLiveByteBudget)
    }
}
