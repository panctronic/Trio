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
}

/// Records the outcome of every upload to Nightscout, Tidepool and Apple Health, so the Sync Status
/// screen can show when each kind of data last went out and what the last error was.
///
/// The managers call `recordSuccess` / `recordFailure` from whatever task or queue the upload runs
/// on. The record survives a relaunch in a small JSON file. Observers listen for
/// `SyncStatusTracker.didChange` (posted on the calling thread).
///
/// `@unchecked Sendable`: the only mutable state sits in `state`'s lock, and the file write happens
/// inside that lock; `FileStorage` (`BaseFileStorage`) serialises its own file access.
final class SyncStatusTracker: @unchecked Sendable {
    static let didChange = Notification.Name("SyncStatusTracker.didChange")
    static let file = "upload/sync-status.json"
    static let maxMessageLength = 300

    private let storage: FileStorage?
    private let now: @Sendable() -> Date
    private let state: OSAllocatedUnfairLock<SyncStatusSnapshot>

    /// - Parameter storage: where the record is persisted; `nil` keeps it in memory only.
    init(storage: FileStorage?, now: @escaping @Sendable() -> Date = { Date() }) {
        self.storage = storage
        self.now = now
        let stored = storage?.retrieve(Self.file, as: SyncStatusSnapshot.self) ?? SyncStatusSnapshot()
        state = OSAllocatedUnfairLock(initialState: stored)
    }

    var snapshot: SyncStatusSnapshot {
        state.withLock { $0 }
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
            snapshot[destination].failures[kind] = nil
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
        }
    }

    private func update(_ change: (inout SyncStatusSnapshot) -> Void) {
        // Unchecked: `change` and `storage` are used only while the lock is held.
        state.withLockUnchecked { snapshot in
            change(&snapshot)
            storage?.save(snapshot, as: Self.file)
        }
        Foundation.NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
