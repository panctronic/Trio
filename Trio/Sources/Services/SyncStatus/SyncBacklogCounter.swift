import CoreData
import Foundation

/// Counts the records each destination still has to upload, with the same predicates the upload
/// passes fetch with, plus the deletions waiting in that destination's `PendingDeletionQueue`.
///
/// Counts run on a background context and read only counts and one date per query, so they stay
/// cheap even with a large backlog.
struct SyncBacklogCounter {
    /// One "not yet uploaded" query.
    struct PendingQuery {
        let kind: SyncDataKind
        let entityName: String
        let predicate: NSPredicate
        /// The date attribute the predicate's upload window filters on.
        let dateKey: String
    }

    let fileStorage: FileStorage

    /// The upload passes' queries for `destination`.
    ///
    /// - Parameter includeNightscoutGlucose: false when glucose upload to Nightscout is switched off;
    ///   those rows are never uploaded and would otherwise look stuck.
    static func pendingQueries(for destination: SyncDestination, includeNightscoutGlucose: Bool = true) -> [PendingQuery] {
        switch destination {
        case .nightscout:
            var queries = [
                PendingQuery(
                    kind: .treatments,
                    entityName: "PumpEventStored",
                    predicate: .pumpEventsNotYetUploadedToNightscout,
                    dateKey: "timestamp"
                ),
                PendingQuery(
                    kind: .carbs,
                    entityName: "CarbEntryStored",
                    predicate: NSCompoundPredicate(orPredicateWithSubpredicates: [
                        .carbsNotYetUploadedToNightscout,
                        .fpusNotYetUploadedToNightscout
                    ]),
                    dateKey: "date"
                ),
                PendingQuery(
                    kind: .adjustments,
                    entityName: "OverrideStored",
                    predicate: .lastActiveAdjustmentNotYetUploadedToNightscout,
                    dateKey: "date"
                ),
                PendingQuery(
                    kind: .adjustments,
                    entityName: "OverrideRunStored",
                    predicate: .adjustmentRunsNotYetUploadedToNightscout,
                    dateKey: "endDate"
                ),
                PendingQuery(
                    kind: .adjustments,
                    entityName: "TempTargetStored",
                    predicate: .lastActiveAdjustmentNotYetUploadedToNightscout,
                    dateKey: "date"
                ),
                PendingQuery(
                    kind: .adjustments,
                    entityName: "TempTargetRunStored",
                    predicate: .adjustmentRunsNotYetUploadedToNightscout,
                    dateKey: "endDate"
                )
            ]
            if includeNightscoutGlucose {
                queries.insert(
                    PendingQuery(
                        kind: .glucose,
                        entityName: "GlucoseStored",
                        predicate: .glucoseNotYetUploadedToNightscout,
                        dateKey: "date"
                    ),
                    at: 0
                )
            }
            return queries

        case .tidepool:
            return [
                PendingQuery(
                    kind: .glucose,
                    entityName: "GlucoseStored",
                    predicate: .glucoseNotYetUploadedToTidepool,
                    dateKey: "date"
                ),
                PendingQuery(
                    kind: .treatments,
                    entityName: "PumpEventStored",
                    predicate: .pumpEventsNotYetUploadedToTidepool,
                    dateKey: "timestamp"
                ),
                PendingQuery(
                    kind: .carbs,
                    entityName: "CarbEntryStored",
                    predicate: .carbsNotYetUploadedToTidepool,
                    dateKey: "date"
                )
            ]

        case .appleHealth:
            return [
                PendingQuery(
                    kind: .glucose,
                    entityName: "GlucoseStored",
                    predicate: .glucoseNotYetUploadedToHealth,
                    dateKey: "date"
                ),
                PendingQuery(
                    kind: .treatments,
                    entityName: "PumpEventStored",
                    predicate: .pumpEventsNotYetUploadedToHealth,
                    dateKey: "timestamp"
                ),
                PendingQuery(
                    kind: .carbs,
                    entityName: "CarbEntryStored",
                    predicate: .carbsNotYetUploadedToHealth,
                    dateKey: "date"
                )
            ]
        }
    }

    static func pendingDeletionsFile(for destination: SyncDestination) -> String {
        switch destination {
        case .nightscout: return OpenAPS.Nightscout.pendingDeletionsNightscout
        case .tidepool: return OpenAPS.Nightscout.pendingDeletionsTidepool
        case .appleHealth: return OpenAPS.Nightscout.pendingDeletionsAppleHealth
        }
    }

    private static func logCategory(for destination: SyncDestination) -> Logger.Category {
        switch destination {
        case .nightscout: return .nightscout
        case .tidepool: return .tidepool
        case .appleHealth: return .healthKit
        }
    }

    /// Counts the backlog of `destination`. Returns `nil` if Core Data could not be read.
    func backlog(for destination: SyncDestination, includeNightscoutGlucose: Bool = true) async -> SyncBacklog? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "SyncBacklogCounter.\(destination.rawValue)"

        let counted: (byKind: [SyncDataKind: Int], oldest: Date?)? = await context.perform {
            // Built here so the (non-Sendable) predicates never cross into the context's queue.
            let queries = Self.pendingQueries(for: destination, includeNightscoutGlucose: includeNightscoutGlucose)
            do {
                var byKind: [SyncDataKind: Int] = [:]
                var oldest: Date?
                for query in queries {
                    let count = try context.count(for: Self.countRequest(query))
                    byKind[query.kind, default: 0] += count
                    guard count > 0, let date = try Self.oldestDate(query, in: context) else { continue }
                    oldest = min(oldest ?? date, date)
                }
                return (byKind, oldest)
            } catch {
                warning(.storage, "Counting records waiting for \(destination.rawValue) failed", error: error)
                return nil
            }
        }
        guard let counted else { return nil }

        let deletions = await PendingDeletionQueue(
            storage: fileStorage,
            file: Self.pendingDeletionsFile(for: destination),
            category: Self.logCategory(for: destination)
        ).pending

        return SyncBacklog(
            pendingByKind: counted.byKind,
            oldestPending: counted.oldest,
            pendingDeletions: deletions.count,
            oldestPendingDeletion: deletions.map(\.queuedAt).min()
        )
    }

    private static func countRequest(_ query: PendingQuery) -> NSFetchRequest<NSFetchRequestResult> {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: query.entityName)
        request.predicate = query.predicate
        request.includesPropertyValues = false
        request.includesSubentities = false
        return request
    }

    private static func oldestDate(_ query: PendingQuery, in context: NSManagedObjectContext) throws -> Date? {
        let request = NSFetchRequest<NSDictionary>(entityName: query.entityName)
        request.predicate = query.predicate
        request.sortDescriptors = [NSSortDescriptor(key: query.dateKey, ascending: true)]
        request.fetchLimit = 1
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = [query.dateKey]
        return try context.fetch(request).first?[query.dateKey] as? Date
    }
}
