import Foundation
import Testing

@testable import Trio

@Suite("IOB Loop Age Hint Tests") struct IOBLoopAgeHintTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("No hint while the last loop is recent") func recentLoop() {
        #expect(IOBLoopAgeHint(lastLoopDate: now, now: now) == nil)
        #expect(IOBLoopAgeHint(lastLoopDate: now.addingTimeInterval(-5 * 60), now: now) == nil)
        #expect(IOBLoopAgeHint(lastLoopDate: now.addingTimeInterval(-IOBLoopAgeHint.threshold), now: now) == nil)
    }

    @Test("Hint with the loop age once the loop is overdue") func overdueLoop() throws {
        let lastLoop = now.addingTimeInterval(-15 * 60)
        let hint = try #require(IOBLoopAgeHint(lastLoopDate: lastLoop, now: now))
        #expect(hint.lastLoopDate == lastLoop)
        #expect(hint.text.contains("15"))
        #expect(hint.spokenText.contains("15"))
    }

    @Test("No age when there was no loop in the last day") func noRecentLoop() throws {
        let never = try #require(IOBLoopAgeHint(lastLoopDate: .distantPast, now: now))
        #expect(never.lastLoopDate == nil)
        #expect(never.text == String(localized: "No recent loop", comment: "Hint under IOB on Home when Trio has not looped for over a day"))

        let twoDays = try #require(IOBLoopAgeHint(lastLoopDate: now.addingTimeInterval(-48 * 3600), now: now))
        #expect(twoDays.lastLoopDate == nil)
    }
}
