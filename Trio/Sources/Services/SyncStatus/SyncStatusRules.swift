import Foundation

/// Records still waiting for one destination, as counted by `SyncBacklogCounter`.
struct SyncBacklog: Equatable, Sendable {
    var pendingByKind: [SyncDataKind: Int] = [:]
    /// Date of the oldest record still waiting, by the date its upload query filters on.
    var oldestPending: Date?
    /// Remote deletions that failed and wait in `PendingDeletionQueue`.
    var pendingDeletions: Int = 0
    var oldestPendingDeletion: Date?
    /// Nightscout only: when the loop last made a determination. Each one should be followed by a
    /// device status upload, which has no "not yet uploaded" rows of its own to count.
    var latestDetermination: Date?

    var pendingUploads: Int { pendingByKind.values.reduce(0, +) }
}

/// Whether a destination is set up to receive uploads.
enum SyncAvailability: Equatable, Sendable {
    /// Not set up, or uploads are switched off.
    case off
    /// Set up, but something outside the upload passes stops them (expired login, missing permission
    /// or credentials). The message tells the user what to fix.
    case blocked(String)
    case on
}

/// The headline status of one destination.
enum SyncHealth: Equatable, Sendable {
    case ok
    case behind
    case error
    case off
}

enum SyncStatusRules {
    /// Records younger than this are normal: the upload controllers pick them up within seconds,
    /// but a pass can wait for the phone to be unlocked or back online.
    static let behindAfter: TimeInterval = 30 * 60

    /// A failure older than this, with no retry since, no longer turns the status red: the record
    /// that failed has either been uploaded under another kind or nothing is waiting any more.
    /// Failing passes are retried and re-recorded, so a lasting outage keeps its failure fresh.
    static let failureRelevance: TimeInterval = 24 * 60 * 60

    /// Records this close to leaving the upload window are highlighted: after that they are never
    /// uploaded.
    static let windowWarning: TimeInterval = 24 * 60 * 60

    /// When a record dated `date` drops out of the destination's upload query. Mirrors the
    /// `Date.<destination>UploadWindowStart` computation in `NSPredicates.swift`.
    static func windowEnd(for date: Date, destination: SyncDestination, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: destination.uploadWindowDays, to: date) ?? date
    }

    /// True when the oldest waiting record leaves the upload window within `windowWarning` (or
    /// already has, which can happen between the count and the next pass).
    static func isNearWindowLimit(
        oldestPending: Date?,
        destination: SyncDestination,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let oldestPending else { return false }
        return windowEnd(for: oldestPending, destination: destination, calendar: calendar)
            .timeIntervalSince(now) <= windowWarning
    }

    /// True when the loop has made determinations recently but no device status reached Nightscout
    /// for `behindAfter`: followers would see a stale loop. When the loop itself is not running there
    /// is nothing to upload, and the loop warnings elsewhere cover it.
    static func isDeviceStatusOverdue(record: SyncDestinationRecord, latestDetermination: Date?, now: Date) -> Bool {
        guard let latestDetermination, now.timeIntervalSince(latestDetermination) <= behindAfter else { return false }
        guard let lastUpload = record.lastSuccess[.deviceStatus] else { return true }
        return now.timeIntervalSince(lastUpload) > behindAfter
    }

    /// Failures that still count against the destination.
    static func activeFailures(_ record: SyncDestinationRecord, now: Date) -> [SyncFailure] {
        record.failures.values
            .filter { now.timeIntervalSince($0.date) <= failureRelevance }
            .sorted { $0.date > $1.date }
    }

    /// - Parameter backlog: `nil` while the counts are not known; the status then rests on the
    ///   recorded failures alone.
    static func classify(
        destination: SyncDestination,
        availability: SyncAvailability,
        record: SyncDestinationRecord,
        backlog: SyncBacklog?,
        now: Date,
        calendar: Calendar = .current
    ) -> SyncHealth {
        switch availability {
        case .off: return .off
        case .blocked: return .error
        case .on: break
        }

        if activeFailures(record, now: now).isNotEmpty {
            return .error
        }

        guard let backlog else { return .ok }

        if backlog.pendingDeletions > 0 {
            return .behind
        }
        if destination == .nightscout,
           isDeviceStatusOverdue(record: record, latestDetermination: backlog.latestDetermination, now: now)
        {
            return .behind
        }
        if let oldest = backlog.oldestPending {
            if now.timeIntervalSince(oldest) > behindAfter
                || isNearWindowLimit(oldestPending: oldest, destination: destination, now: now, calendar: calendar)
            {
                return .behind
            }
        }
        return .ok
    }
}
