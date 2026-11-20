import Foundation
import os

/// A remote place Trio copies its data to.
enum SyncDestination: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case nightscout
    case tidepool
    case appleHealth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nightscout: return "Nightscout"
        case .tidepool: return "Tidepool"
        case .appleHealth: return String(localized: "Apple Health")
        }
    }

    /// How many days back the destination's "not yet uploaded" queries look (see `UploadBacklog`).
    var uploadWindowDays: Int {
        switch self {
        case .nightscout: return UploadBacklog.nightscoutDays
        case .tidepool: return UploadBacklog.tidepoolDays
        case .appleHealth: return UploadBacklog.appleHealthDays
        }
    }

    /// The kinds of data this destination receives, in display order.
    var dataKinds: [SyncDataKind] {
        switch self {
        case .nightscout: return [.glucose, .treatments, .carbs, .overrides, .tempTargets, .deviceStatus]
        case .appleHealth,
             .tidepool: return [.glucose, .treatments, .carbs]
        }
    }
}

/// The groups of records the upload passes send.
enum SyncDataKind: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case glucose
    /// Pump history: boluses, temp basals and other pump events.
    case treatments
    case carbs
    /// Overrides and override runs; one Nightscout upload pipeline.
    case overrides
    /// Temp targets and temp target runs; one Nightscout upload pipeline.
    case tempTargets
    case deviceStatus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glucose: return String(localized: "Glucose", comment: "Sync status data kind")
        case .treatments: return String(localized: "Insulin and Pump Events", comment: "Sync status data kind")
        case .carbs: return String(localized: "Carbs", comment: "Sync status data kind")
        case .overrides: return String(localized: "Overrides")
        case .tempTargets: return String(localized: "Temp Targets")
        case .deviceStatus: return String(localized: "Device Status", comment: "Sync status data kind")
        }
    }
}

/// An upload that failed and has not been followed by a successful upload of the same kind.
struct SyncFailure: Codable, Equatable, Sendable {
    let kind: SyncDataKind
    let message: String
    let date: Date
}

/// What is known about one destination's uploads.
struct SyncDestinationRecord: Codable, Equatable, Sendable {
    var lastSuccess: [SyncDataKind: Date] = [:]
    /// At most one unresolved failure per kind; a later success of that kind removes it.
    var failures: [SyncDataKind: SyncFailure] = [:]

    var lastSuccessDate: Date? { lastSuccess.values.max() }
    var latestFailure: SyncFailure? { failures.values.max { $0.date < $1.date } }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lastSuccess
        case failures
    }

    /// Entries for kinds this build doesn't know (written by another version) are dropped rather
    /// than failing the whole record.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let successes = try container.decodeIfPresent([String: Date].self, forKey: .lastSuccess) ?? [:]
        lastSuccess = Dictionary(uniqueKeysWithValues: successes.compactMap { key, date in
            SyncDataKind(rawValue: key).map { ($0, date) }
        })
        let storedFailures = try container.decodeIfPresent([String: StoredFailure].self, forKey: .failures) ?? [:]
        failures = Dictionary(uniqueKeysWithValues: storedFailures.compactMap { key, stored in
            SyncDataKind(rawValue: key).map { ($0, SyncFailure(kind: $0, message: stored.message, date: stored.date)) }
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            Dictionary(uniqueKeysWithValues: lastSuccess.map { ($0.key.rawValue, $0.value) }),
            forKey: .lastSuccess
        )
        try container.encode(
            Dictionary(uniqueKeysWithValues: failures.map { ($0.key.rawValue, $0.value) }),
            forKey: .failures
        )
    }

    /// A failure as stored, decoded without its `kind` so an unknown kind is skipped, not fatal.
    private struct StoredFailure: Decodable {
        let message: String
        let date: Date
    }
}

/// The outcome of one upload pass for one kind of data, which may send several batches or
/// sub-uploads (e.g. carbs and fat/protein equivalents, overrides and override runs).
///
/// The pass counts as a success only when something was sent and every part of it was accepted;
/// a pass that sent nothing records nothing. So a failed batch is not hidden by a later batch, or
/// an empty sub-upload, that went through.
struct SyncPassOutcome: Sendable {
    private(set) var sentSomething = false
    private(set) var firstFailureMessage: String?

    var isEmpty: Bool { !sentSomething && firstFailureMessage == nil }

    mutating func succeeded() {
        sentSomething = true
    }

    mutating func failed(_ error: Error) {
        failed(message: error.localizedDescription)
    }

    mutating func failed(message: String) {
        sentSomething = true
        if firstFailureMessage == nil {
            firstFailureMessage = message
        }
    }

    mutating func merge(_ other: SyncPassOutcome) {
        sentSomething = sentSomething || other.sentSomething
        if firstFailureMessage == nil {
            firstFailureMessage = other.firstFailureMessage
        }
    }

    static var success: SyncPassOutcome {
        var outcome = SyncPassOutcome()
        outcome.succeeded()
        return outcome
    }

    static func failure(_ error: Error) -> SyncPassOutcome {
        var outcome = SyncPassOutcome()
        outcome.failed(error)
        return outcome
    }

    static func failure(message: String) -> SyncPassOutcome {
        var outcome = SyncPassOutcome()
        outcome.failed(message: message)
        return outcome
    }
}

struct SyncStatusSnapshot: JSON, Equatable, Sendable {
    var destinations: [SyncDestination: SyncDestinationRecord] = [:]

    subscript(destination: SyncDestination) -> SyncDestinationRecord {
        get { destinations[destination] ?? SyncDestinationRecord() }
        set { destinations[destination] = newValue }
    }

    /// Combines this record (read late from the file) with `newer` (recorded in memory meanwhile):
    /// the later upload time wins, the later failure wins, and a failure older than the kind's
    /// last upload is dropped.
    func merged(with newer: SyncStatusSnapshot) -> SyncStatusSnapshot {
        var result = self
        for (destination, record) in newer.destinations {
            var merged = result[destination]
            for (kind, date) in record.lastSuccess {
                merged.lastSuccess[kind] = max(merged.lastSuccess[kind] ?? date, date)
            }
            for (kind, failure) in record.failures where (merged.failures[kind]?.date ?? .distantPast) <= failure.date {
                merged.failures[kind] = failure
            }
            for (kind, failure) in merged.failures where (merged.lastSuccess[kind] ?? .distantPast) >= failure.date {
                merged.failures[kind] = nil
            }
            result[destination] = merged
        }
        return result
    }
}

/// Records the outcome of every upload to Nightscout, Tidepool and Apple Health, so the Sync Status
/// screen can show when each kind of data last went out and what the last error was.
///
/// The managers call `record` / `recordSuccess` / `recordFailure` from whatever task or queue the
/// upload runs on. Observers listen for `SyncStatusTracker.didChange` (posted on the calling thread).
///
/// The record survives a relaunch in a small JSON file. Updates only touch memory under the lock;
/// the file is written on `writeQueue` with the latest snapshot. A change to the failures is written
/// right away; a change that only moves a "last upload" time is written at most once a minute, so
/// a relaunch may show a last upload up to a minute older than it was.
///
/// `@unchecked Sendable`: the mutable state sits in `state`'s lock; `storage` and `fileExists` are
/// used only in `init` and on `writeQueue`.
final class SyncStatusTracker: @unchecked Sendable {
    static let didChange = Notification.Name("SyncStatusTracker.didChange")
    static let file = "upload/sync-status.json"
    static let maxMessageLength = 300
    /// Minimum time between writes caused only by new "last upload" times.
    static let minWriteInterval: TimeInterval = 60

    private struct State {
        var snapshot: SyncStatusSnapshot
        /// Memory holds changes the file doesn't have yet.
        var needsWrite = false
        var lastWrite: Date?
        /// When the next write is due, if one is scheduled.
        var writeDue: Date?
        /// The file exists but could not be read (protected data before the first unlock). Nothing
        /// is written until it has been read, so the first write doesn't replace it.
        var fileUnreadable = false
    }

    private enum StoredRecord {
        case loaded(SyncStatusSnapshot)
        /// No file, or a file that reads but doesn't decode (it is replaced).
        case missing
        case unreadable
    }

    private let storage: FileStorage?
    private let now: @Sendable() -> Date
    private let state: OSAllocatedUnfairLock<State>
    private let writeQueue = DispatchQueue(label: "SyncStatusTracker.write", qos: .utility)
    private let fileExists: (String) -> Bool
    /// How long to wait before trying an unreadable file again.
    static let unreadableRetryInterval: TimeInterval = 60

    /// - Parameters:
    ///   - storage: where the record is persisted; `nil` keeps it in memory only.
    ///   - fileExists: whether a file is present even if it can't be read; defaults to checking
    ///     the storage's URL on disk.
    init(
        storage: FileStorage?,
        now: @escaping @Sendable() -> Date = { Date() },
        fileExists: ((String) -> Bool)? = nil
    ) {
        self.storage = storage
        self.now = now
        self.fileExists = fileExists ?? { name in
            if let url = storage?.urlFor(file: name) {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return storage?.retrieveRaw(name) != nil
        }
        var initial = State(snapshot: SyncStatusSnapshot())
        switch Self.read(storage, fileExists: self.fileExists) {
        case let .loaded(snapshot): initial.snapshot = snapshot
        case .missing: break
        case .unreadable:
            initial.fileUnreadable = true
            warning(.storage, "Sync status file can't be read yet; keeping it until it can")
        }
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    private static func read(_ storage: FileStorage?, fileExists: (String) -> Bool) -> StoredRecord {
        guard let storage else { return .missing }
        if let snapshot = storage.retrieve(file, as: SyncStatusSnapshot.self) {
            return .loaded(snapshot)
        }
        guard fileExists(file) else { return .missing }
        // Present but undecodable is replaced; present but unreadable is kept.
        return storage.retrieveRaw(file) == nil ? .unreadable : .missing
    }

    var snapshot: SyncStatusSnapshot {
        state.withLock { $0.snapshot }
    }

    /// Records a whole upload pass of `kind`: a failure if any part failed, a success if
    /// everything sent was accepted, nothing if nothing was sent.
    func record(_ outcome: SyncPassOutcome, _ destination: SyncDestination, _ kind: SyncDataKind) {
        if let message = outcome.firstFailureMessage {
            recordFailure(destination, kind, message: message)
        } else if outcome.sentSomething {
            recordSuccess(destination, kind)
        }
    }

    /// The destination accepted a batch of `kind`. Clears an earlier failure of the same kind.
    func recordSuccess(_ destination: SyncDestination, _ kind: SyncDataKind) {
        let date = now()
        update { snapshot in
            snapshot[destination].lastSuccess[kind] = date
            // Clearing a failure changes what the screen shows after a relaunch: write it now.
            return snapshot[destination].failures.removeValue(forKey: kind) != nil
        }
    }

    /// The destination did not accept a batch of `kind`.
    func recordFailure(_ destination: SyncDestination, _ kind: SyncDataKind, error: Error) {
        recordFailure(destination, kind, message: error.localizedDescription)
    }

    func recordFailure(_ destination: SyncDestination, _ kind: SyncDataKind, message: String) {
        let failure = SyncFailure(kind: kind, message: String(message.prefix(Self.maxMessageLength)), date: now())
        update { snapshot in
            snapshot[destination].failures[kind] = failure
            return true
        }
    }

    /// Writes pending changes now and waits for the write. For tests and orderly shutdown.
    func flush() {
        writeQueue.sync { write(force: true) }
    }

    /// Waits for writes that are already due. For tests.
    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    /// - Parameter change: returns `true` when the change should reach the file right away.
    private func update(_ change: (inout SyncStatusSnapshot) -> Bool) {
        // Unchecked: `change` runs only while the lock is held.
        let delay: TimeInterval? = state.withLockUnchecked { state in
            let urgent = change(&state.snapshot)
            state.needsWrite = true

            let current = now()
            let throttled = state.lastWrite.map { $0.addingTimeInterval(Self.minWriteInterval) } ?? current
            let due = urgent ? current : max(current, throttled)
            if let scheduled = state.writeDue, scheduled <= due {
                return nil
            }
            state.writeDue = due
            return due.timeIntervalSince(current)
        }
        if let delay, storage != nil {
            writeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.write(force: false)
            }
        }
        Foundation.NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Runs on `writeQueue`. Copies the latest snapshot under the lock and writes it outside.
    private func write(force: Bool) {
        guard let storage else { return }
        guard loadFileIfStillUnreadable() else {
            writeQueue.asyncAfter(deadline: .now() + Self.unreadableRetryInterval) { [weak self] in
                self?.write(force: false)
            }
            return
        }
        let current = now()
        enum Step { case idle, wait(TimeInterval), save(SyncStatusSnapshot) }
        let step: Step = state.withLock { state in
            guard state.needsWrite else { return .idle }
            // An earlier timer that fired after a later write was scheduled, or a timer that fired a
            // little before the clock reached its due time: wait for the due time.
            if !force, let due = state.writeDue, due > current {
                return .wait(due.timeIntervalSince(current))
            }
            state.needsWrite = false
            state.writeDue = nil
            state.lastWrite = current
            return .save(state.snapshot)
        }
        switch step {
        case .idle:
            break
        case let .wait(delay):
            writeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.write(force: false)
            }
        case let .save(snapshot):
            storage.save(snapshot, as: Self.file)
        }
    }

    /// Runs on `writeQueue`. If the file couldn't be read at launch, reads it now and merges what
    /// was recorded since. Returns `false` while it still can't be read.
    private func loadFileIfStillUnreadable() -> Bool {
        guard state.withLock({ $0.fileUnreadable }) else { return true }
        let stored = Self.read(storage, fileExists: fileExists)
        if case .unreadable = stored { return false }
        state.withLock { state in
            if case let .loaded(snapshot) = stored {
                state.snapshot = snapshot.merged(with: state.snapshot)
            }
            state.fileUnreadable = false
        }
        Foundation.NotificationCenter.default.post(name: Self.didChange, object: self)
        return true
    }
}
