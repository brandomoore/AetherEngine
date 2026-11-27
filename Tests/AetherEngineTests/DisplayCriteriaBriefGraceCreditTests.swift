import Foundation
import Testing
@testable import AetherEngine

// When the engine writes display criteria synchronously before loadNative, loadNative typically takes
// longer than `.brief`'s 200 ms start grace. Crediting elapsed time since `apply()` avoids a redundant
// 200 ms blind poll when no switch started, while keeping one immediate poll on gate entry so an already
// running switch still enters Stage 2.
@Suite("Display criteria brief grace elapsed-time credit", .timeLimit(.minutes(3)))
struct DisplayCriteriaBriefGraceCreditTests {

    private let ms: UInt64 = 1_000_000
    private let writtenAt: UInt64 = 10_000 * 1_000_000

    // MARK: - effectiveStartGraceMs

    @Test("Brief grace with zero elapsed time keeps the full 200 ms budget")
    func briefZeroElapsedKeepsFullBudget() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .brief,
            creditElapsedSinceWrite: true,
            writtenAtNanos: writtenAt,
            gateEntryNanos: writtenAt
        ) == 200)
    }

    @Test("Brief grace deducts partial elapsed time since the synchronous write")
    func briefPartialElapsedDeductsRemainingBudget() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .brief,
            creditElapsedSinceWrite: true,
            writtenAtNanos: writtenAt,
            gateEntryNanos: writtenAt + 80 * ms
        ) == 120)
    }

    @Test("Brief grace reaches zero at exactly 200 ms elapsed")
    func briefExactBudgetElapsedReturnsZero() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .brief,
            creditElapsedSinceWrite: true,
            writtenAtNanos: writtenAt,
            gateEntryNanos: writtenAt + 200 * ms
        ) == 0)
    }

    @Test("Brief grace clamps to zero when load time exceeds 200 ms")
    func briefLongLoadClampsToZero() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .brief,
            creditElapsedSinceWrite: true,
            writtenAtNanos: writtenAt,
            gateEntryNanos: writtenAt + 1_500 * ms
        ) == 0)
    }

    @Test("Clock skew with gate entry before write clamps elapsed time to zero")
    func briefClockSkewKeepsFullBudget() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .brief,
            creditElapsedSinceWrite: true,
            writtenAtNanos: writtenAt,
            gateEntryNanos: writtenAt - 50 * ms
        ) == 200)
    }

    @Test("Missing write timestamp never shortens brief grace")
    func briefWithoutWriteTimestampKeepsFullBudget() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .brief,
            creditElapsedSinceWrite: true,
            writtenAtNanos: nil,
            gateEntryNanos: writtenAt + 1_500 * ms
        ) == 200)
    }

    @Test("Non-engine writers (AVKit sole-writer or host-owned) never receive credit")
    func briefCreditDisabledKeepsFullBudget() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .brief,
            creditElapsedSinceWrite: false,
            writtenAtNanos: writtenAt,
            gateEntryNanos: writtenAt + 1_500 * ms
        ) == 200)
    }

    @Test("Full grace is never shortened by elapsed time since write")
    func fullGraceNeverShortened() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .full,
            creditElapsedSinceWrite: true,
            writtenAtNanos: writtenAt,
            gateEntryNanos: writtenAt + 1_500 * ms
        ) == 1000)
    }

    @Test("Skip grace stays zero regardless of credit flag")
    func skipGraceStaysZero() {
        #expect(DisplayCriteriaController.effectiveStartGraceMs(
            startGrace: .skip,
            creditElapsedSinceWrite: true,
            writtenAtNanos: writtenAt,
            gateEntryNanos: writtenAt
        ) == 0)
    }

    // MARK: - Stage 1 immediate first-poll invariant

    @Test("Zero budget still classifies an active in-progress switch on the first poll and enters Stage 2")
    func zeroBudgetActiveSwitchEntersStage2() {
        let verdict = DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: true,
            hasNewEnd: false,
            headroomSettles: false,
            startNotificationFired: false,
            switchInProgress: true,
            elapsedMs: 0,
            budgetMs: 0
        )
        #expect(verdict == .started(.preGate))
    }

    @Test("Zero budget still honors a start notification on the first poll")
    func zeroBudgetStartNotificationEntersStage2() {
        let verdict = DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: true,
            hasNewEnd: false,
            headroomSettles: false,
            startNotificationFired: true,
            switchInProgress: false,
            elapsedMs: 0,
            budgetMs: 0
        )
        #expect(verdict == .started(.inGate))
    }

    @Test("Zero budget still settles immediately when a mode-switch end or headroom is present on first poll")
    func zeroBudgetImmediateSettle() {
        #expect(DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: true,
            hasNewEnd: true,
            headroomSettles: false,
            startNotificationFired: false,
            switchInProgress: false,
            elapsedMs: 0,
            budgetMs: 0
        ) == .settled)
        #expect(DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: true,
            hasNewEnd: false,
            headroomSettles: true,
            startNotificationFired: false,
            switchInProgress: false,
            elapsedMs: 0,
            budgetMs: 0
        ) == .settled)
    }

    @Test("Zero budget with an idle panel exits immediately with zero sleep ticks")
    func zeroBudgetIdlePanelExitsWithoutSleep() {
        let verdict = DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: true,
            hasNewEnd: false,
            headroomSettles: false,
            startNotificationFired: false,
            switchInProgress: false,
            elapsedMs: 0,
            budgetMs: 0
        )
        #expect(verdict == .noSwitch)
    }

    @Test("Non-zero remaining budget keeps polling until elapsed time spends the budget")
    func nonZeroBudgetPollsUntilSpent() {
        #expect(DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: true,
            hasNewEnd: false,
            headroomSettles: false,
            startNotificationFired: false,
            switchInProgress: false,
            elapsedMs: 0,
            budgetMs: 120
        ) == .pollAgain)
        #expect(DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: false,
            hasNewEnd: false,
            headroomSettles: false,
            startNotificationFired: false,
            switchInProgress: false,
            elapsedMs: 119,
            budgetMs: 120
        ) == .pollAgain)
        #expect(DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: false,
            hasNewEnd: false,
            headroomSettles: false,
            startNotificationFired: false,
            switchInProgress: false,
            elapsedMs: 120,
            budgetMs: 120
        ) == .noSwitch)
    }

    @Test("A flag rising on a later poll still classifies as in-gate flag-only even at the budget boundary")
    func laterPollFlagAtBoundaryEntersStage2() {
        let verdict = DisplayCriteriaController.stage1PollVerdict(
            isFirstPoll: false,
            hasNewEnd: false,
            headroomSettles: false,
            startNotificationFired: false,
            switchInProgress: true,
            elapsedMs: 120,
            budgetMs: 120
        )
        #expect(verdict == .started(.inGateFlagOnly))
    }

    @Test("Both software and native play gates credit elapsed time since engine criteria write")
    func bothPlayGatesCreditElapsedTimeSinceEngineCriteriaWrite() throws {
        let engineFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine.swift")
        let source = try String(contentsOf: engineFile, encoding: .utf8)
        let expected = "creditElapsedSinceWrite: options.engineWritesDisplayCriteria && !options.awaitsInboundCriteriaWrite"
        let matches = source.components(separatedBy: expected).count - 1
        #expect(matches == 2, "expected both the software and native play-gate waitForSwitch sites to pass creditElapsedSinceWrite")
    }
}
