import Foundation
import Testing

@testable import Trio

@Suite("APS: LoopGuard standalone determinations") struct LoopGuardTests {
    @Test("A free guard is claimed immediately") func claimsWhenFree() async {
        let loopGuard = LoopGuard()
        #expect(await loopGuard.claimStandaloneDetermination(timeout: 1))
    }

    @Test("A second request waits for the running one and then runs its own") func waitsForRunning() async {
        let loopGuard = LoopGuard()
        #expect(await loopGuard.claimStandaloneDetermination(timeout: 1))

        let second = Task { await loopGuard.claimStandaloneDetermination(timeout: 5) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await loopGuard.finishStandaloneDetermination()

        #expect(await second.value, "the waiting request must get its own run, not be skipped")
    }

    @Test("A request gives up after the timeout instead of reporting success") func timesOut() async {
        let loopGuard = LoopGuard()
        #expect(await loopGuard.claimStandaloneDetermination(timeout: 1))
        #expect(await loopGuard.claimStandaloneDetermination(timeout: 0.2) == false)
        await loopGuard.finishStandaloneDetermination()
    }

    @Test("Only one of several waiters runs at a time") func oneAtATime() async {
        let loopGuard = LoopGuard()
        #expect(await loopGuard.claimStandaloneDetermination(timeout: 1))

        let a = Task { await loopGuard.claimStandaloneDetermination(timeout: 0.6) }
        let b = Task { await loopGuard.claimStandaloneDetermination(timeout: 0.6) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await loopGuard.finishStandaloneDetermination()

        // One claims the guard; the other waits on it and times out because nobody finishes.
        let results = [await a.value, await b.value]
        #expect(results.filter { $0 }.count == 1)
    }
}
