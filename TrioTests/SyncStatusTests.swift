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

/// File storage that can't read or write while "locked", like protected data before the first unlock.
private final class LockableFileStorage: FileStorage, @unchecked Sendable {
    let backing = InMemoryFileStorage()
    private let lockedState = OSAllocatedUnfairLock(initialState: false)
    var locked: Bool {
        get { lockedState.withLock { $0 } }
        set { lockedState.withLock { $0 = newValue } }
    }

    func save<Value: JSON>(_ value: Value, as name: String) { if !locked { backing.save(value, as: name) } }
    func saveAsync<Value: JSON>(_ value: Value, as name: String) async { save(value, as: name) }
    func retrieve<Value: JSON>(_ name: String, as type: Value.Type) -> Value? {
        locked ? nil : backing.retrieve(name, as: type)
    }

    func retrieveAsync<Value: JSON>(_ name: String, as type: Value.Type) async -> Value? { retrieve(name, as: type) }
    func retrieveRaw(_ name: String) -> RawJSON? { locked ? nil : backing.retrieveRaw(name) }
    func retrieveRawAsync(_ name: String) async -> RawJSON? { retrieveRaw(name) }
    func append<Value: JSON>(_: Value, to _: String) {}
    func append<Value: JSON>(_: [Value], to _: String) {}
    func append<Value: JSON, T: Equatable>(_: Value, to _: String, uniqBy _: KeyPath<Value, T>) {}
    func append<Value: JSON, T: Equatable>(_: [Value], to _: String, uniqBy _: KeyPath<Value, T>) {}
    func remove(_ name: String) { backing.remove(name) }
    func rename(_ name: String, to newName: String) { backing.rename(name, to: newName) }
    func transaction(_ exec: (FileStorage) -> Void) { exec(self) }
    func urlFor(file _: String) -> URL? { nil }
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
        tracker.flush()

        let relaunched = SyncStatusTracker(storage: storage)
        #expect(relaunched.snapshot == tracker.snapshot)
        #expect(relaunched.snapshot[.nightscout].lastSuccess[.deviceStatus] == clock.now)
    }

    @Test("Failures reach the file right away") func failuresWrittenPromptly() {
        let storage = InMemoryFileStorage()
        let clock = SyncTestClock()
        let tracker = SyncStatusTracker(storage: storage, now: { clock.now })

        tracker.recordFailure(.nightscout, .glucose, message: "offline")
        tracker.waitForPendingWrites()

        #expect(storage.retrieve(SyncStatusTracker.file, as: SyncStatusSnapshot.self)?[.nightscout].failures[.glucose] != nil)
    }

    @Test("New upload times are written at most once a minute") func successesThrottled() {
        let storage = InMemoryFileStorage()
        let clock = SyncTestClock()
        let tracker = SyncStatusTracker(storage: storage, now: { clock.now })
        let stored = { storage.retrieve(SyncStatusTracker.file, as: SyncStatusSnapshot.self) ?? SyncStatusSnapshot() }

        // Nothing written yet: the first change goes out right away.
        tracker.recordSuccess(.nightscout, .glucose)
        tracker.waitForPendingWrites()
        #expect(stored()[.nightscout].lastSuccess[.glucose] == clock.now)

        // Within a minute of that write, a new time stays in memory.
        clock.advance(10)
        tracker.recordSuccess(.nightscout, .carbs)
        tracker.waitForPendingWrites()
        #expect(stored()[.nightscout].lastSuccess[.carbs] == nil)
        #expect(tracker.snapshot[.nightscout].lastSuccess[.carbs] == clock.now)

        // A success that clears a failure is not held back.
        tracker.recordFailure(.tidepool, .carbs, message: "HTTP 500")
        tracker.waitForPendingWrites()
        clock.advance(5)
        tracker.recordSuccess(.tidepool, .carbs)
        tracker.waitForPendingWrites()
        #expect(stored()[.tidepool].failures[.carbs] == nil)

        tracker.flush()
        #expect(stored() == tracker.snapshot)
    }

    @Test("A file that can't be read yet is kept, then merged once it can") func unreadableFileIsKept() throws {
        let storage = LockableFileStorage()
        let clock = SyncTestClock()
        var onDisk = SyncStatusSnapshot()
        onDisk[.tidepool].lastSuccess[.glucose] = clock.now.addingTimeInterval(-3600)
        onDisk[.nightscout]
            .failures[.carbs] = SyncFailure(kind: .carbs, message: "HTTP 500", date: clock.now.addingTimeInterval(-60))
        storage.backing.save(onDisk, as: SyncStatusTracker.file)
        storage.locked = true

        let tracker = SyncStatusTracker(storage: storage, now: { clock.now }, fileExists: { _ in true })
        #expect(tracker.snapshot == SyncStatusSnapshot())

        // Recorded while locked: kept in memory, the file is not replaced.
        tracker.recordSuccess(.nightscout, .carbs)
        storage.locked = false
        let untouched = try #require(storage.backing.retrieve(SyncStatusTracker.file, as: SyncStatusSnapshot.self))
        #expect(untouched == onDisk)

        // Once readable, the next write merges both.
        tracker.flush()
        let merged = tracker.snapshot
        #expect(merged[.tidepool].lastSuccess[.glucose] == onDisk[.tidepool].lastSuccess[.glucose])
        #expect(merged[.nightscout].lastSuccess[.carbs] == clock.now)
        #expect(merged[.nightscout].failures[.carbs] == nil) // cleared by the later success
        #expect(storage.backing.retrieve(SyncStatusTracker.file, as: SyncStatusSnapshot.self) == merged)
    }

    @Test("A missing or undecodable file starts empty and is replaced") func missingOrCorrupt() {
        let storage = InMemoryFileStorage()
        #expect(SyncStatusTracker(storage: storage).snapshot == SyncStatusSnapshot())

        storage.save("not json" as RawJSON, as: SyncStatusTracker.file)
        let tracker = SyncStatusTracker(storage: storage)
        #expect(tracker.snapshot == SyncStatusSnapshot())
        tracker.recordFailure(.nightscout, .glucose, message: "offline")
        tracker.waitForPendingWrites()
        #expect(storage.retrieve(SyncStatusTracker.file, as: SyncStatusSnapshot.self)?[.nightscout].failures[.glucose] != nil)
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

@Suite("Sync pass outcome") struct SyncPassOutcomeTests {
    @Test("A failed batch is not hidden by a later batch that went through") func failureWins() {
        let tracker = SyncStatusTracker(storage: nil)
        tracker.recordSuccess(.tidepool, .glucose)

        var pass = SyncPassOutcome()
        pass.failed(SyncTestError(errorDescription: "HTTP 503"))
        pass.succeeded()
        tracker.record(pass, .tidepool, .glucose)

        #expect(tracker.snapshot[.tidepool].failures[.glucose]?.message == "HTTP 503")
    }

    @Test("The first failure of a pass is the one recorded") func firstFailure() {
        var pass = SyncPassOutcome.failure(message: "first")
        pass.merge(.failure(message: "second"))
        pass.merge(.success)
        #expect(pass.firstFailureMessage == "first")
    }

    @Test("A pass that sent nothing records nothing") func emptyPass() {
        let tracker = SyncStatusTracker(storage: nil)
        tracker.recordFailure(.nightscout, .overrides, message: "offline")

        var pass = SyncPassOutcome()
        pass.merge(SyncPassOutcome())
        #expect(pass.isEmpty)
        tracker.record(pass, .nightscout, .overrides)

        #expect(tracker.snapshot[.nightscout].failures[.overrides]?.message == "offline")
        #expect(tracker.snapshot[.nightscout].lastSuccess[.overrides] == nil)
    }

    @Test("A pass where every part went through clears the failure") func allSucceeded() {
        let tracker = SyncStatusTracker(storage: nil)
        tracker.recordFailure(.nightscout, .carbs, message: "offline")

        var pass = SyncPassOutcome.success
        pass.merge(SyncPassOutcome())
        pass.merge(.success)
        tracker.record(pass, .nightscout, .carbs)

        #expect(tracker.snapshot[.nightscout].failures[.carbs] == nil)
        #expect(tracker.snapshot[.nightscout].lastSuccess[.carbs] != nil)
    }

    @Test("Overrides and temp targets are tracked apart") func adjustmentsSeparate() {
        let tracker = SyncStatusTracker(storage: nil)
        tracker.record(.failure(message: "offline"), .nightscout, .overrides)
        tracker.record(.success, .nightscout, .tempTargets)
        #expect(tracker.snapshot[.nightscout].failures[.overrides] != nil)
    }

    @Test("Kinds from another version are skipped when the record is read") func unknownKindsAreSkipped() throws {
        let json = """
        {"destinations":{"nightscout":{"lastSuccess":{"glucose":"2027-01-15T08:00:00.000Z","adjustments":"2027-01-15T08:00:00.000Z"},\
        "failures":{"adjustments":{"kind":"adjustments","message":"x","date":"2027-01-15T08:00:00.000Z"},\
        "carbs":{"kind":"carbs","message":"HTTP 500","date":"2027-01-15T08:00:00.000Z"}}}}}
        """
        let snapshot = try JSONCoding.decoder.decode(SyncStatusSnapshot.self, from: Data(json.utf8))
        #expect(snapshot[.nightscout].lastSuccess.keys.sorted { $0.rawValue < $1.rawValue } == [.glucose])
        #expect(snapshot[.nightscout].failures.keys.sorted { $0.rawValue < $1.rawValue } == [.carbs])
        #expect(snapshot[.nightscout].failures[.carbs]?.message == "HTTP 500")
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

    @Test("Device status counts as behind when the loop runs but nothing reached Nightscout") func deviceStatusOverdue() {
        var record = SyncDestinationRecord()
        let looping = SyncBacklog(latestDetermination: now.addingTimeInterval(-5 * 60))

        // Never uploaded while looping.
        #expect(classify(record: record, backlog: looping) == .behind)

        record.lastSuccess[.deviceStatus] = now.addingTimeInterval(-10 * 60)
        #expect(classify(record: record, backlog: looping) == .ok)

        record.lastSuccess[.deviceStatus] = now.addingTimeInterval(-(SyncStatusRules.behindAfter + 60))
        #expect(classify(record: record, backlog: looping) == .behind)

        // Loop not running: no device status expected.
        let notLooping = SyncBacklog(latestDetermination: now.addingTimeInterval(-3 * hour))
        #expect(classify(record: record, backlog: notLooping) == .ok)
        #expect(classify(record: record, backlog: SyncBacklog()) == .ok)

        // Only Nightscout receives device status.
        #expect(classify(.tidepool, record: SyncDestinationRecord(), backlog: looping) == .ok)
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
        #expect(!SyncBacklogCounter.pendingQueries(for: .tidepool).contains { $0.kind == .overrides || $0.kind == .tempTargets })
    }
}
