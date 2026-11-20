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

@Suite("Next Therapy Profile Switch Tests") struct NextTherapyProfileSwitchTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    // 2026-11-13 is a Friday
    private let nightFriday = ScheduledProfileSwitch(id: "n", profileName: "Night", weekday: 6, time: 22 * 3600)
    private let dayFriday = ScheduledProfileSwitch(id: "d", profileName: "Default", weekday: 6, time: 18 * 3600)
    private let weekendSaturday = ScheduledProfileSwitch(id: "w", profileName: "Weekend", weekday: 7, time: 7 * 3600)

    @Test("Finds the next start of another profile") func nextStart() throws {
        let next = try #require(NextTherapyProfileSwitch.find(
            in: [weekendSaturday, nightFriday],
            activeProfileName: "Default",
            after: date("2026-11-13 12:00"),
            calendar: calendar
        ))
        #expect(next == NextTherapyProfileSwitch(profileName: "Night", date: date("2026-11-13 22:00")))
    }

    @Test("Skips starts of the profile that is already active") func skipsActiveProfile() throws {
        let next = try #require(NextTherapyProfileSwitch.find(
            in: [dayFriday, nightFriday],
            activeProfileName: "Default",
            after: date("2026-11-13 12:00"),
            calendar: calendar
        ))
        #expect(next.profileName == "Night")
    }

    @Test("Paused starts and an empty schedule show nothing") func pausedOrEmpty() {
        var paused = nightFriday
        paused.paused = true
        #expect(NextTherapyProfileSwitch.find(
            in: [paused],
            activeProfileName: "Default",
            after: date("2026-11-13 12:00"),
            calendar: calendar
        ) == nil)
        #expect(NextTherapyProfileSwitch.find(
            in: [],
            activeProfileName: "Default",
            after: date("2026-11-13 12:00"),
            calendar: calendar
        ) == nil)
    }

    @Test("Names the profile in the text") func text() {
        let next = NextTherapyProfileSwitch(profileName: "Weekend", date: date("2026-11-14 07:00"))
        #expect(next.text(now: date("2026-11-13 12:00"), calendar: calendar).contains("Weekend"))
        #expect(next.text(now: date("2026-11-14 06:00"), calendar: calendar).contains("Weekend"))
    }
}
