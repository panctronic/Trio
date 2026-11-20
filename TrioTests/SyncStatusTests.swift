import Foundation
import os
import Testing
@testable import Trio

private struct SyncTestError: LocalizedError {
    let errorDescription: String?
}

/// A settable clock for the tracker.
private final class SyncTestClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(_ interval: TimeInterval) { current.withLock { $0 += interval } }
}

@Suite("Sync status tracker") struct SyncStatusTrackerTests {
    @Test("A success records its time and clears the failure of the same kind only") func successClearsSameKind() {
        let clock = SyncTestClock()
        let tracker = SyncStatusTracker(storage: nil, now: { clock.now })

        tracker.recordFailure(.nightscout, .glucose, error: SyncTestError(errorDescription: "offline"))
        tracker.recordFailure(.nightscout, .carbs, message: "HTTP 500")
        clock.advance(60)
        tracker.recordSuccess(.nightscout, .glucose)

        let record = tracker.snapshot[.nightscout]
        #expect(record.lastSuccess[.glucose] == clock.now)
        #expect(record.failures[.glucose] == nil)
        #expect(record.failures[.carbs]?.message == "HTTP 500")
        #expect(tracker.snapshot[.tidepool] == SyncDestinationRecord())
    }

    @Test("The latest failure and the latest success are reported") func latestValues() {
        let clock = SyncTestClock()
        let tracker = SyncStatusTracker(storage: nil, now: { clock.now })

        tracker.recordSuccess(.tidepool, .carbs)
        clock.advance(10)
        tracker.recordSuccess(.tidepool, .glucose)
        tracker.recordFailure(.tidepool, .treatments, message: "first")
        clock.advance(10)
        tracker.recordFailure(.tidepool, .carbs, message: "second")

        let record = tracker.snapshot[.tidepool]
        #expect(record.lastSuccessDate == clock.now.addingTimeInterval(-10))
        #expect(record.latestFailure?.message == "second")
        #expect(record.latestFailure?.kind == .carbs)
    }

    @Test("Long error messages are shortened") func messageIsTruncated() {
        let tracker = SyncStatusTracker(storage: nil)
        tracker.recordFailure(.appleHealth, .glucose, message: String(repeating: "x", count: 1000))
        #expect(tracker.snapshot[.appleHealth].failures[.glucose]?.message.count == SyncStatusTracker.maxMessageLength)
    }

    @Test("The record survives a relaunch") func persists() {
        let storage = InMemoryFileStorage()
        let clock = SyncTestClock()
        let tracker = SyncStatusTracker(storage: storage, now: { clock.now })
        tracker.recordSuccess(.nightscout, .deviceStatus)
        tracker.recordFailure(.appleHealth, .treatments, message: "Not authorized")

        let relaunched = SyncStatusTracker(storage: storage)
        #expect(relaunched.snapshot == tracker.snapshot)
        #expect(relaunched.snapshot[.nightscout].lastSuccess[.deviceStatus] == clock.now)
    }

    @Test("Changes are announced") func postsChange() {
        let tracker = SyncStatusTracker(storage: nil)
        let received = OSAllocatedUnfairLock(initialState: false)
        let observer = Foundation.NotificationCenter.default.addObserver(
            forName: SyncStatusTracker.didChange,
            object: tracker,
            queue: nil
        ) { _ in received.withLock { $0 = true } }
        defer { Foundation.NotificationCenter.default.removeObserver(observer) }

        tracker.recordSuccess(.nightscout, .glucose)
        #expect(received.withLock { $0 })
    }
}

@Suite("Sync status classification") struct SyncStatusRulesTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 60 * 60
    private let day: TimeInterval = 24 * 60 * 60

    private func classify(
        _ destination: SyncDestination = .nightscout,
        availability: SyncAvailability = .on,
        record: SyncDestinationRecord = SyncDestinationRecord(),
        backlog: SyncBacklog? = SyncBacklog()
    ) -> SyncHealth {
        SyncStatusRules.classify(
            destination: destination,
            availability: availability,
            record: record,
            backlog: backlog,
            now: now,
            calendar: calendar
        )
    }

    private func record(failureAge: TimeInterval) -> SyncDestinationRecord {
        var record = SyncDestinationRecord()
        record.failures[.glucose] = SyncFailure(kind: .glucose, message: "failed", date: now.addingTimeInterval(-failureAge))
        return record
    }

    private func backlog(oldestAge: TimeInterval?, deletions: Int = 0) -> SyncBacklog {
        SyncBacklog(
            pendingByKind: oldestAge == nil ? [:] : [.glucose: 3],
            oldestPending: oldestAge.map { now.addingTimeInterval(-$0) },
            pendingDeletions: deletions
        )
    }

    @Test("Nothing waiting and no failures is OK") func ok() {
        #expect(classify() == .ok)
        #expect(classify(backlog: nil) == .ok)
    }

    @Test("A destination that is off is off, whatever was recorded") func off() {
        #expect(classify(availability: .off, record: record(failureAge: 60), backlog: backlog(oldestAge: 3 * day)) == .off)
    }

    @Test("A blocked destination is an error") func blocked() {
        #expect(classify(availability: .blocked("Log in again")) == .error)
    }

    @Test("A recent unresolved failure is an error and wins over a backlog") func recentFailure() {
        #expect(classify(record: record(failureAge: hour)) == .error)
        #expect(classify(record: record(failureAge: hour), backlog: backlog(oldestAge: 2 * hour)) == .error)
        #expect(classify(record: record(failureAge: hour), backlog: nil) == .error)
    }

    @Test("A failure older than a day without a retry no longer counts") func staleFailure() {
        #expect(classify(record: record(failureAge: SyncStatusRules.failureRelevance + 1)) == .ok)
        #expect(SyncStatusRules.activeFailures(record(failureAge: SyncStatusRules.failureRelevance + 1), now: now).isEmpty)
    }

    @Test("Records waiting longer than the grace period put the destination behind") func behind() {
        #expect(classify(backlog: backlog(oldestAge: 10 * 60)) == .ok)
        #expect(classify(backlog: backlog(oldestAge: SyncStatusRules.behindAfter + 1)) == .behind)
    }

    @Test("Waiting deletions put the destination behind") func deletionsBehind() {
        #expect(classify(backlog: backlog(oldestAge: nil, deletions: 1)) == .behind)
    }

    @Test("Nightscout records within a day of the 7-day window end are near the limit") func nightscoutWindow() {
        let near = now.addingTimeInterval(-(6 * day + hour))
        let notNear = now.addingTimeInterval(-(5 * day))
        #expect(SyncStatusRules.isNearWindowLimit(oldestPending: near, destination: .nightscout, now: now, calendar: calendar))
        #expect(
            !SyncStatusRules
                .isNearWindowLimit(oldestPending: notNear, destination: .nightscout, now: now, calendar: calendar)
        )
        #expect(
            SyncStatusRules.windowEnd(for: near, destination: .nightscout, calendar: calendar)
                == near.addingTimeInterval(7 * day)
        )
    }

    @Test("Tidepool and Apple Health use their 30-day window") func longerWindows() {
        let sixDays = now.addingTimeInterval(-(6 * day + hour))
        let twentyNineDays = now.addingTimeInterval(-(29 * day + hour))
        for destination in [SyncDestination.tidepool, .appleHealth] {
            #expect(
                !SyncStatusRules
                    .isNearWindowLimit(oldestPending: sixDays, destination: destination, now: now, calendar: calendar)
            )
            #expect(SyncStatusRules.isNearWindowLimit(
                oldestPending: twentyNineDays,
                destination: destination,
                now: now,
                calendar: calendar
            ))
        }
    }

    @Test("Records already past the window, or none at all") func windowEdges() {
        let past = now.addingTimeInterval(-(8 * day))
        #expect(SyncStatusRules.isNearWindowLimit(oldestPending: past, destination: .nightscout, now: now, calendar: calendar))
        #expect(!SyncStatusRules.isNearWindowLimit(oldestPending: nil, destination: .nightscout, now: now, calendar: calendar))
    }

    @Test("The row for the screen carries the window warning") func row() {
        let row = SyncStatus.StateModel.row(
            destination: .nightscout,
            availability: .on,
            record: SyncDestinationRecord(),
            backlog: SyncBacklog(pendingByKind: [.carbs: 1], oldestPending: Date().addingTimeInterval(-(6 * day + 2 * hour))),
            now: Date()
        )
        #expect(row.health == .behind)
        #expect(row.isNearWindowLimit)
        #expect(row.windowEnd != nil)
    }
}

@Suite("Sync backlog queries") struct SyncBacklogQueryTests {
    @Test("Nightscout glucose is only counted when glucose upload is on") func nightscoutGlucose() {
        let withGlucose = SyncBacklogCounter.pendingQueries(for: .nightscout, includeNightscoutGlucose: true)
        let withoutGlucose = SyncBacklogCounter.pendingQueries(for: .nightscout, includeNightscoutGlucose: false)
        #expect(withGlucose.contains { $0.kind == .glucose })
        #expect(!withoutGlucose.contains { $0.kind == .glucose })
        #expect(withGlucose.count == withoutGlucose.count + 1)
    }

    @Test("Each destination counts only the kinds it receives") func kindsMatchDestinations() {
        for destination in SyncDestination.allCases {
            let kinds = Set(SyncBacklogCounter.pendingQueries(for: destination).map(\.kind))
            #expect(kinds.isSubset(of: Set(destination.dataKinds)))
            #expect(!kinds.contains(.deviceStatus))
        }
        #expect(!SyncBacklogCounter.pendingQueries(for: .tidepool).contains { $0.kind == .adjustments })
    }
}
