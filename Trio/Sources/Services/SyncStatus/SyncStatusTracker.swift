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
        case .nightscout: return [.glucose, .treatments, .carbs, .adjustments, .deviceStatus]
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
    /// Overrides and temp targets.
    case adjustments
    case deviceStatus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glucose: return String(localized: "Glucose", comment: "Sync status data kind")
        case .treatments: return String(localized: "Insulin and Pump Events", comment: "Sync status data kind")
        case .carbs: return String(localized: "Carbs", comment: "Sync status data kind")
        case .adjustments: return String(localized: "Overrides and Temp Targets", comment: "Sync status data kind")
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
