import Combine
import CoreData
import Foundation
import SwiftDate
import Swinject

protocol CarbsObserver {
    func carbsDidUpdate(_ carbs: [CarbsEntry])
}

protocol CarbsStorage {
    var updatePublisher: AnyPublisher<Void, Never> { get }
    /// Remote entries' Nightscout `_id`s are recorded for `nightscoutSiteURL`, the site they were fetched from.
    func storeCarbs(_ carbs: [CarbsEntry], areFetchedFromRemote: Bool, nightscoutSiteURL: String?) async throws
    /// Builds a single, real, locally-entered carb entry ready to pass to `storeCarbs`.
    func makeCarbEntry(carbs: Decimal, date: Date) -> CarbsEntry
    /// Swaps a stored meal in one Core Data transaction.
    /// - Returns: The fpuID of unlinked carb equivalents deleted with an old meal that had no fpuID, so remote copies
    ///   can be deleted too.
    @discardableResult func replaceCarbs(_ treatmentObjectID: NSManagedObjectID, with entry: CarbsEntry) async throws -> UUID?
    /// - Returns: The fpuID of unlinked carb equivalents deleted with a meal that had no fpuID, so remote copies
    ///   can be deleted too.
    @discardableResult func deleteCarbsEntryStored(_ treatmentObjectID: NSManagedObjectID) async -> UUID?
    func syncDate() -> Date
    func getCarbsForAlgorithm(additionalCarbs: Decimal?, carbsDate: Date?) async throws -> [CarbsEntry]
    func getCarbsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func getFPUsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment]
    func getCarbsNotYetUploadedToHealth() async throws -> [CarbsEntry]
    func getCarbsNotYetUploadedToTidepool() async throws -> [CarbsEntry]
    /// Resolves a meal root by its own `id` or by the family's `fpuID`, which is the Nightscout `id` of every carb equivalent.
    func fetchMealRoot(handle: UUID) async throws -> (objectID: NSManagedObjectID, snapshot: MealSnapshot)?
}

extension CarbsStorage {
    func storeCarbs(_ carbs: [CarbsEntry], areFetchedFromRemote: Bool) async throws {
        try await storeCarbs(carbs, areFetchedFromRemote: areFetchedFromRemote, nightscoutSiteURL: nil)
    }
}

enum CarbsStorageError: Error, Equatable {
    case ambiguousMealHandle(UUID)
}

final class BaseCarbsStorage: CarbsStorage, Injectable {
    private let processQueue = DispatchQueue(label: "BaseCarbsStorage.processQueue")
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settings: SettingsManager!

    private let updateSubject = PassthroughSubject<Void, Never>()

    private let settingsProvider = PickerSettingsProvider.shared

    var updatePublisher: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    private let makeContext: () -> NSManagedObjectContext
    private let storeQueue = SerialStoreQueue()

    init(resolver: Resolver, contextProvider: (() -> NSManagedObjectContext)? = nil) {
        makeContext = contextProvider ?? { CoreDataStack.shared.newTaskContext() }
        injectServices(resolver)
    }

    func storeCarbs(_ entries: [CarbsEntry], areFetchedFromRemote: Bool, nightscoutSiteURL: String?) async throws {
        // One store at a time: two overlapping Nightscout fetches could both pass filterRemoteEntries before
        // either saved, and every new remote meal was then stored twice (double COB)
        try await storeQueue.run {
            try await self.storeSerially(
                entries,
                areFetchedFromRemote: areFetchedFromRemote,
                nightscoutSiteURL: nightscoutSiteURL
            )
        }
    }

    private func storeSerially(_ entries: [CarbsEntry], areFetchedFromRemote: Bool, nightscoutSiteURL: String?) async throws {
        var entriesToStore = entries

        if areFetchedFromRemote {
            entriesToStore = try await filterRemoteEntries(entries: entriesToStore)
        }

        // Each meal is stored with its own carb equivalents. Only the last entry used to be saved, so a Nightscout
        // fetch returning several new meals kept one, and its equivalents took the first entry's fpuID.
        // A meal with fat or protein must share an fpuID with its equivalents, or deleting it leaves them behind.
        for entry in entriesToStore.map(Self.withFPUIDIfNeeded) {
            try await saveCarbsToCoreData(
                entry,
                areFetchedFromRemote: areFetchedFromRemote,
                nightscoutSiteURL: nightscoutSiteURL
            )
            await saveCarbEquivalents(
                for: entry,
                areFetchedFromRemote: areFetchedFromRemote,
                nightscoutSiteURL: nightscoutSiteURL
            )
        }
    }

    /// Gives a meal with fat or protein an `fpuID` if it has none, so the meal and the carb equivalents made from it
    /// are linked. Without it the equivalents got an fpuID of their own and stayed, as phantom COB, when the meal was deleted.
    static func withFPUIDIfNeeded(_ entry: CarbsEntry) -> CarbsEntry {
        guard entry.fpuID == nil, entry.isFPU != true, (entry.fat ?? 0) > 0 || (entry.protein ?? 0) > 0 else { return entry }
        return CarbsEntry(
            id: entry.id,
            createdAt: entry.createdAt,
            actualDate: entry.actualDate,
            carbs: entry.carbs,
            fat: entry.fat,
            protein: entry.protein,
            note: entry.note,
            enteredBy: entry.enteredBy,
            isFPU: entry.isFPU,
            fpuID: UUID().uuidString
        )
    }

    private func filterRemoteEntries(entries: [CarbsEntry]) async throws -> [CarbsEntry] {
        let context = makeContext()
        context.name = "filterRemoteEntries"
        // Fetch only the date property from Core Data
        // Extract dates into a set for efficient lookup
        let existingTimestamps = try await CoreDataStack.shared.fetchDictionaries(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForOneDayAgo,
            key: "date",
            ascending: false,
            batchSize: 50,
            propertiesToFetch: ["date", "objectID"]
        ) { existing24hCarbEntries in
            Set(existing24hCarbEntries.compactMap { $0["date"] as? Date })
        }

        // Remove all entries that have a matching date in existingTimestamps, and repeats within the batch, since
        // every entry of a batch is now stored
        var seenTimestamps = existingTimestamps
        return entries.filter { entry in
            seenTimestamps.insert(entry.actualDate ?? entry.createdAt).inserted
        }
    }

    /**
     Converts fat and protein into delayed carb-equivalent entries (FPU handling).

     Behavior:

     - Calculates carb equivalents from fat and protein
       ((fat × 9 + protein × 4) / 10 × adjustment factor).
     - Rounds down to whole grams.
     - Drops values below 10 g.
     - Caps total equivalents at 99 g.
     - Splits into up to 3 entries.
     - Caps each entry at 33 g.
     - Distributes grams as evenly as possible.

     Timing:

     - First entry is scheduled after the configured delay
       (default: 60 minutes) from the carb entry timestamp.
     - Additional entries are spaced 30 minutes apart.

     Example (default):

     - Carb entry at T
     - 1st equivalent at T + 60 min
     - 2nd equivalent at T + 90 min
     - 3rd equivalent at T + 120 min

     Generated entries:

     - Are marked with `isFPU = true`
     - Contain only carbs (fat and protein set to 0)
     - Share the same `fpuID` as the original carb entry

     - Parameters:
       - entries: An array of `CarbsEntry` objects representing the carb equivalent entries to be processed.
       - fat: The amount of fat in the last entry.
       - protein: The amount of protein in the last entry.
       - createdAt: The creation date of the last entry.

     - Returns: A tuple containing the array of future carb entries and the total carb equivalents.
     */
    private func processFPU(
        entries: [CarbsEntry],
        fat: Decimal,
        protein: Decimal,
        createdAt: Date,
        actualDate: Date?
    ) -> ([CarbsEntry], Decimal) {
        let trioSettings = settings.settings
        let providerSettings = settingsProvider.settings

        let adjustment = trioSettings.individualAdjustmentFactor
            .clamp(to: providerSettings.individualAdjustmentFactor)

        let delayMinutes = trioSettings.delay
            .clamp(to: providerSettings.delay)

        let spreadInterval = trioSettings.minuteInterval
            .clamp(to: providerSettings.minuteInterval)

        // Constraints
        let maxTotalGrams = 99
        let maxEntries = 3
        let maxPerEntry = 33
        let minPerEntry = 10
        let spacing = TimeInterval(spreadInterval * 60)

        // kcal -> carb equivalents (kcal/10 * adjustment), rounded down to whole grams
        let kcal = protein * 4 + fat * 9
        let rawEquivalents = Int((kcal / 10) * adjustment)
        let totalGrams = min(maxTotalGrams, max(0, rawEquivalents))

        guard totalGrams >= minPerEntry else {
            return ([], Decimal(totalGrams))
        }

        let amounts = splitIntoCarbEquivalents(
            total: totalGrams,
            maxEntries: maxEntries,
            maxPerEntry: maxPerEntry,
            minPerEntry: minPerEntry
        )

        let baseDate = actualDate ?? createdAt
        let start = baseDate.addingTimeInterval(TimeInterval(delayMinutes * 60))
        let fpuID = entries.first?.fpuID ?? UUID().uuidString

        let futureEntries: [CarbsEntry] = amounts.enumerated().map { idx, grams in
            CarbsEntry(
                id: UUID().uuidString,
                createdAt: createdAt,
                actualDate: start.addingTimeInterval(TimeInterval(idx) * spacing),
                carbs: Decimal(grams),
                fat: 0,
                protein: 0,
                note: nil,
                enteredBy: CarbsEntry.local,
                isFPU: true,
                fpuID: fpuID
            )
        }

        let totalScheduled = futureEntries.reduce(into: Decimal(0)) { $0 += $1.carbs }
        return (futureEntries, totalScheduled)
    }

    /**
     Splits a total carb-equivalent value into multiple integer entries.

     - Returns no entries if `total` is below `minPerEntry`.
     - Limits output to `maxEntries`.
     - Caps each entry at `maxPerEntry`.
     - Distributes grams evenly (difference ≤ 1 g).
     - Merges or removes entries below `minPerEntry`.

     - Returns:
       Integer gram values representing the split carb equivalents.
     */
    private func splitIntoCarbEquivalents(
        total: Int,
        maxEntries: Int,
        maxPerEntry: Int,
        minPerEntry: Int
    ) -> [Int] {
        guard total >= minPerEntry else { return [] }

        // Choose an entry count that *guarantees* each entry can be <= maxPerEntry
        let needed = (total + maxPerEntry - 1) / maxPerEntry
        let count = min(maxEntries, max(1, needed))

        // Even split (difference between buckets is at most 1)
        func evenSplit(_ total: Int, count: Int) -> [Int] {
            let base = total / count
            let rem = total % count
            return (0 ..< count).map { base + ($0 < rem ? 1 : 0) }
        }

        var buckets = evenSplit(total, count: count)

        // Enforce minPerEntry by merging any too-small tail bucket into the previous one
        // This should be rare, but it keeps the invariant
        if buckets.count > 1 {
            for i in stride(from: buckets.count - 1, through: 1, by: -1) {
                let v = buckets[i]
                guard v > 0, v < minPerEntry else { continue }
                buckets[i - 1] += v
                buckets[i] = 0
            }
            buckets = buckets.filter { $0 > 0 }
        }

        // Guarantee not to exceed maxPerEntry if merging a reduced count
        // Clamp as final guard here
        buckets = buckets.map { min(maxPerEntry, $0) }.filter { $0 >= minPerEntry }

        return buckets
    }

    private func saveCarbEquivalents(for entry: CarbsEntry, areFetchedFromRemote: Bool, nightscoutSiteURL: String?) async {
        let fat = entry.fat ?? 0
        let protein = entry.protein ?? 0
        guard fat > 0 || protein > 0 else { return }

        let (futureCarbEquivalents, carbEquivalentCount) = processFPU(
            entries: [entry],
            fat: fat,
            protein: protein,
            createdAt: entry.createdAt,
            actualDate: entry.actualDate
        )

        if carbEquivalentCount > 0 {
            let isSaved = await saveFPUToCoreDataAsBatchInsert(
                entries: futureCarbEquivalents,
                areFetchedFromRemote: areFetchedFromRemote
            )

            // Equivalents of a downloaded meal are known to Nightscout through the meal's `_id`.
            // Recorded only once they are stored, so no mapping points at rows that do not exist.
            if isSaved, areFetchedFromRemote, let objectId = entry.id {
                let localIds = futureCarbEquivalents.compactMap(\.id) + [futureCarbEquivalents.first?.fpuID].compactMap { $0 }
                NightscoutObjectIdStore.shared.record(localIds.map { ($0, objectId) }, fromSite: nightscoutSiteURL)
            }
        }
    }

    /// Saves one meal root. Throws if Core Data cannot save it, so callers never act on carbs that were not stored.
    private func saveCarbsToCoreData(_ entry: CarbsEntry, areFetchedFromRemote: Bool, nightscoutSiteURL: String?) async throws {
        let context = makeContext()
        context.name = "saveCarbsToCoreData"
        try await context.perform {
            let newItem = self.insertCarbEntry(entry, into: context, areFetchedFromRemote: areFetchedFromRemote)

            guard context.hasChanges else { return }
            do {
                try context.save()
            } catch {
                warning(.storage, "Saving carb entry failed", error: error)
                context.rollback()
                throw error
            }

            // Recorded after the save, so a failed save leaves no mapping to a meal that was never stored
            if areFetchedFromRemote, let localId = newItem.id?.uuidString, let objectId = entry.id {
                NightscoutObjectIdStore.shared.record([(localId, objectId)], fromSite: nightscoutSiteURL)
            }
        }
    }

    /// Inserts a meal root row into `context` without saving, so callers decide when to commit.
    /// A downloaded meal's Nightscout `_id` is recorded by the caller once the save succeeded.
    private func insertCarbEntry(
        _ entry: CarbsEntry,
        into context: NSManagedObjectContext,
        areFetchedFromRemote: Bool
    ) -> CarbEntryStored {
        let newItem = CarbEntryStored(context: context)
        newItem.date = entry.actualDate ?? entry.createdAt
        newItem.carbs = Double(truncating: NSDecimalNumber(decimal: entry.carbs))
        newItem.fat = Double(truncating: NSDecimalNumber(decimal: entry.fat ?? 0))
        newItem.protein = Double(truncating: NSDecimalNumber(decimal: entry.protein ?? 0))
        newItem.note = entry.note
        // Nightscout `_id` values are not UUIDs and are replaced.
        newItem.id = entry.id.flatMap(UUID.init(uuidString:)) ?? UUID()
        newItem.isFPU = false
        newItem.isUploadedToNS = areFetchedFromRemote ? true : false
        newItem.isUploadedToHealth = false
        newItem.isUploadedToTidepool = false

        // Set whenever there is one: a meal with only fat or only protein still has carb equivalents to link
        if let fpuId = entry.fpuID {
            newItem.fpuID = UUID(uuidString: fpuId)
        }
        return newItem
    }

    /// Inserts a locally created carb equivalent row into `context` without saving.
    private func insertCarbEquivalent(_ entry: CarbsEntry, into context: NSManagedObjectContext) {
        let newItem = CarbEntryStored(context: context)
        newItem.date = entry.actualDate
        newItem.carbs = Double(truncating: NSDecimalNumber(decimal: entry.carbs))
        newItem.id = entry.id.flatMap(UUID.init(uuidString:))
        newItem.fpuID = entry.fpuID.flatMap(UUID.init(uuidString:))
        newItem.isFPU = true
        newItem.isUploadedToNS = false
        // do NOT set Health and Tidepool flags to ensure they will NOT be uploaded
    }

    /// Replaces a stored meal, together with any carb equivalents sharing its `fpuID`.
    ///
    /// The deletes and the inserts go through the same context and are committed by a single `save()`.
    /// A failure therefore leaves the old meal in place rather than deleting it without a replacement.
    @discardableResult func replaceCarbs(
        _ treatmentObjectID: NSManagedObjectID,
        with replacement: CarbsEntry
    ) async throws -> UUID? {
        // The new meal and its new carb equivalents must share an fpuID
        let entry = Self.withFPUIDIfNeeded(replacement)
        var carbEquivalents: [CarbsEntry] = []
        if (entry.fat ?? 0) > 0 || (entry.protein ?? 0) > 0 {
            let fat = entry.fat ?? 0
            let protein = entry.protein ?? 0
            (carbEquivalents, _) = processFPU(
                entries: [entry],
                fat: fat,
                protein: protein,
                createdAt: entry.createdAt,
                actualDate: entry.actualDate
            )
        }

        let context = makeContext()
        context.name = "replaceCarbs"
        context.transactionAuthor = "replaceCarbs"

        let orphanedFPUID: UUID? = try await context.perform {
            // A fetch reads the store, so rows removed by a batch delete are not served from the row cache.
            let rootRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            rootRequest.predicate = NSPredicate(format: "SELF == %@", treatmentObjectID)
            rootRequest.fetchLimit = 1

            guard let storedEntry = try context.fetch(rootRequest).first else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }

            // Deleted through the context instead of an NSBatchDeleteRequest, which would commit on its own.
            var orphanedFPUID: UUID?
            if let fpuID = storedEntry.fpuID {
                let familyRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
                familyRequest.predicate = NSPredicate(format: "fpuID == %@", fpuID as CVarArg)
                for entryToDelete in try context.fetch(familyRequest) {
                    context.delete(entryToDelete)
                }
            } else {
                // Otherwise an old unlinked meal's equivalents would stay next to the new ones: double FPU COB
                orphanedFPUID = self.deleteOrphanedCarbEquivalents(of: storedEntry, in: context)
                context.delete(storedEntry)
            }

            _ = self.insertCarbEntry(entry, into: context, areFetchedFromRemote: false)
            for carbEquivalent in carbEquivalents {
                self.insertCarbEquivalent(carbEquivalent, into: context)
            }

            try context.save()
            return orphanedFPUID
        }

        updateSubject.send(())
        return orphanedFPUID
    }

    /// - Returns: `true` if the carb equivalents were stored.
    @discardableResult private func saveFPUToCoreDataAsBatchInsert(
        entries: [CarbsEntry],
        areFetchedFromRemote: Bool
    ) async -> Bool {
        let context = makeContext()
        context.name = "saveFPUToCoreDataAsBatchInsert"

        return await context.perform {
            let commonFPUID = UUID(
                uuidString: entries.first?.fpuID ?? UUID()
                    .uuidString
            ) // all fpus should only get ONE id per batch insert to be able to delete them referencing the fpuID
            var entrySlice = ArraySlice(entries) // convert to ArraySlice
            let batchInsert = NSBatchInsertRequest(entity: CarbEntryStored.entity()) { (managedObject: NSManagedObject) -> Bool in
                guard let carbEntry = managedObject as? CarbEntryStored, let entry = entrySlice.popFirst(),
                      let entryId = entry.id
                else {
                    return true // return true to stop
                }
                carbEntry.date = entry.actualDate
                carbEntry.carbs = Double(truncating: NSDecimalNumber(decimal: entry.carbs))
                carbEntry.id = UUID.init(uuidString: entryId)
                carbEntry.fpuID = commonFPUID
                carbEntry.isFPU = true
                carbEntry.isUploadedToNS = areFetchedFromRemote ? true : false
                // do NOT set Health and Tidepool flags to ensure they will NOT be uploaded
                return false // return false to continue
            }
            do {
                try context.execute(batchInsert)
                debug(.storage, "Saved \(entries.count) fat and protein entries")

                // Notify subscriber in Home State Model to update the FPU Array
                self.updateSubject.send(())
                return true
            } catch {
                warning(.storage, "Saving fat and protein entries failed", error: error)
                return false
            }
        }
    }

    func syncDate() -> Date {
        Date().addingTimeInterval(-1.days.timeInterval)
    }

    /// Fetches the last day of carbs and converts them into the `CarbsEntry` values the oref algorithm
    /// consumes, optionally appending a synthetic "additional carbs" entry for bolus simulation.
    func getCarbsForAlgorithm(additionalCarbs: Decimal? = nil, carbsDate: Date? = nil) async throws -> [CarbsEntry] {
        let context = makeContext()
        return try await CoreDataStack.shared.fetchAndMap(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForOneDayAgo,
            key: "date",
            ascending: false
        ) { carbResults in
            var entries = carbResults.map { Self.mapToCarbsEntry($0) }

            if let additionalCarbs = additionalCarbs {
                entries.append(Self.additionalCarbsEntry(carbs: additionalCarbs, date: carbsDate ?? Date()))
            }

            return entries
        }
    }

    /// Converts CoreData stored carb entries into a struct that the oref algorithm can use
    static func mapToCarbsEntry(_ carbEntry: CarbEntryStored) -> CarbsEntry {
        // The old encode used `date ?? Date()` for both created_at and actualDate.
        let date = carbEntry.date ?? Date()
        return CarbsEntry(
            id: carbEntry.id?.uuidString,
            createdAt: date,
            actualDate: date,
            carbs: Decimal(algorithmValue: carbEntry.carbs),
            fat: Decimal(algorithmValue: carbEntry.fat),
            protein: Decimal(algorithmValue: carbEntry.protein),
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: carbEntry.isFPU,
            fpuID: nil
        )
    }

    /// Builds the synthetic "additional carbs" entry that the determine-basal flow appends for bolus
    /// simulation.
    static func additionalCarbsEntry(carbs: Decimal, date: Date, id: String = UUID().uuidString) -> CarbsEntry {
        CarbsEntry(
            id: id,
            createdAt: date,
            actualDate: date,
            carbs: carbs,
            fat: 0,
            protein: 0,
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: nil
        )
    }

    /// Builds a single, real, locally-entered carb entry ready to pass to `storeCarbs`. Kept separate from
    /// `additionalCarbsEntry`, which is for the determine-basal flow's synthetic bolus-simulation input.
    func makeCarbEntry(carbs: Decimal, date: Date) -> CarbsEntry {
        CarbsEntry(
            id: UUID().uuidString,
            createdAt: date,
            actualDate: date,
            carbs: carbs,
            fat: 0,
            protein: 0,
            note: nil,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: nil
        )
    }

    @discardableResult func deleteCarbsEntryStored(_ treatmentObjectID: NSManagedObjectID) async -> UUID? {
        let context = makeContext()
        context.name = "deleteCarbsEntryStored"

        var carbEntryFromCoreData: CarbEntryStored?
        var deletedOrphanFPUID: UUID?

        await context.perform {
            do {
                carbEntryFromCoreData = try context.existingObject(with: treatmentObjectID) as? CarbEntryStored
                guard let carbEntry = carbEntryFromCoreData else {
                    warning(.storage, "Carb entry to delete not found")
                    return
                }

                // entry has fpuID
                // case 1: carb equivalent entry
                // case 2: "parent" entry, but containing fat and/or protein, and possibly carbs
                // => use fpuID ID to delete all corresponding entries via batch delete
                if let fpuID = carbEntry.fpuID {
                    // fetch request for all carb entries with the same id
                    let fetchRequest: NSFetchRequest<NSFetchRequestResult> = CarbEntryStored.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "fpuID == %@", fpuID as CVarArg)

                    // NSBatchDeleteRequest
                    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                    deleteRequest.resultType = .resultTypeCount

                    // execute the batch delete request
                    let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                    debug(.storage, "Deleted \(result?.result ?? 0) carb entries with FPU ID \(fpuID)")

                    // Notifiy subscribers of the batch delete
                    self.updateSubject.send(())
                }
                // entry has no fpuID
                // => it's a carb-only entry. use its ID to for deletion
                else {
                    let orphanedFPUID = self.deleteOrphanedCarbEquivalents(of: carbEntry, in: context)

                    context.delete(carbEntry)

                    guard context.hasChanges else { return }
                    try context.save()
                    deletedOrphanFPUID = orphanedFPUID

                    debug(.storage, "Deleted carb entry")
                }

            } catch {
                warning(.storage, "Deleting carb entry failed", error: error)
            }
        }
        return deletedOrphanFPUID
    }

    /// Meals with fat or protein saved without an fpuID (e.g. by older Shortcut versions) left their carb equivalents
    /// under an fpuID of their own. Deletes those in `context`, without saving, when they match `meal` unambiguously.
    /// A failed lookup deletes nothing extra and never stops the meal itself from being deleted.
    /// Must be called on `context`'s queue.
    /// - Returns: The fpuID of the deleted equivalents.
    private func deleteOrphanedCarbEquivalents(of meal: CarbEntryStored, in context: NSManagedObjectContext) -> UUID? {
        guard let orphanedFPUID = try? orphanedCarbEquivalentsID(for: meal, in: context) else { return nil }

        let orphanRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
        orphanRequest.predicate = NSPredicate(format: "fpuID == %@ AND isFPU == YES", orphanedFPUID as CVarArg)
        guard let orphans = try? context.fetch(orphanRequest), !orphans.isEmpty else { return nil }
        orphans.forEach(context.delete)
        debug(.storage, "Deleting \(orphans.count) unlinked carb equivalents with meal")
        return orphanedFPUID
    }

    /// Finds the carb equivalents made from `meal` when the meal itself has no `fpuID` to link them.
    ///
    /// Matches only a group of carb equivalents that no meal links to, that starts within the longest possible fat/protein
    /// delay after the meal, and that no other unlinked fat/protein meal could also have made. Returns `nil` otherwise,
    /// so an uncertain match never deletes carbs that belong to another meal.
    /// Must be called on `context`'s queue.
    private func orphanedCarbEquivalentsID(for meal: CarbEntryStored, in context: NSManagedObjectContext) throws -> UUID? {
        guard !meal.isFPU, meal.fpuID == nil, meal.fat > 0 || meal.protein > 0, let mealDate = meal.date else { return nil }

        let providerSettings = settingsProvider.settings
        let maxDelay = TimeInterval(Double(truncating: providerSettings.delay.max as NSNumber) * 60)
        // Up to 3 equivalents are spread over the interval after the first one
        let maxSpread = TimeInterval(Double(truncating: providerSettings.minuteInterval.max as NSNumber) * 60 * 2)

        func window(after date: Date) -> ClosedRange<Date> {
            date.addingTimeInterval(1) ... date.addingTimeInterval(maxDelay)
        }

        // fpuIDs of carb equivalents that may belong to this meal
        let equivalentsRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
        equivalentsRequest.predicate = NSPredicate(
            format: "isFPU == YES AND fpuID != nil AND date > %@ AND date <= %@",
            mealDate as NSDate,
            mealDate.addingTimeInterval(maxDelay + maxSpread) as NSDate
        )
        let nearbyIDs = Array(Set(try context.fetch(equivalentsRequest).compactMap(\.fpuID)))
        guard !nearbyIDs.isEmpty else { return nil }

        // A group whose first equivalent lies before this meal belongs to an earlier one
        let groupStart = try earliestDates(of: nearbyIDs, in: context)
        let startingAfterMeal = nearbyIDs.filter { id in
            groupStart[id].map { window(after: mealDate).contains($0) } == true
        }
        guard !startingAfterMeal.isEmpty else { return nil }

        // Skip groups a meal still links to
        let linkedRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
        linkedRequest.predicate = NSPredicate(format: "isFPU == NO AND fpuID IN %@", startingAfterMeal)
        let linkedIDs = Set(try context.fetch(linkedRequest).compactMap(\.fpuID))
        let orphanIDs = startingAfterMeal.filter { !linkedIDs.contains($0) }
        guard !orphanIDs.isEmpty else { return nil }

        // Other unlinked fat/protein meals that could have made the same equivalents
        let otherMealsRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
        otherMealsRequest.predicate = NSPredicate(
            format: "isFPU == NO AND fpuID == nil AND (fat > 0 OR protein > 0) AND date >= %@ AND date <= %@ AND SELF != %@",
            mealDate.addingTimeInterval(-maxDelay) as NSDate,
            mealDate.addingTimeInterval(maxDelay) as NSDate,
            meal.objectID
        )
        let otherMealDates = try context.fetch(otherMealsRequest).compactMap(\.date)

        let unambiguous = orphanIDs.filter { id in
            guard let start = groupStart[id] else { return false }
            return !otherMealDates.contains { window(after: $0).contains(start) }
        }
        guard unambiguous.count == 1, orphanIDs.count == 1 else {
            warning(.storage, "Unlinked carb equivalents near the deleted meal not deleted: match is ambiguous")
            return nil
        }
        return unambiguous.first
    }

    /// The date of the first entry of each fpuID group, over all stored entries.
    private func earliestDates(of fpuIDs: [UUID], in context: NSManagedObjectContext) throws -> [UUID: Date] {
        let request: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
        request.predicate = NSPredicate(format: "isFPU == YES AND fpuID IN %@", fpuIDs)
        var earliest: [UUID: Date] = [:]
        for entry in try context.fetch(request) {
            guard let fpuID = entry.fpuID, let date = entry.date else { continue }
            earliest[fpuID] = min(earliest[fpuID] ?? date, date)
        }
        return earliest
    }

    func fetchMealRoot(handle: UUID) async throws -> (objectID: NSManagedObjectID, snapshot: MealSnapshot)? {
        let context = makeContext()
        context.name = "fetchMealRoot"

        return try await context.perform {
            let request: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "(id == %@ OR fpuID == %@) AND isFPU == NO",
                handle as CVarArg,
                handle as CVarArg
            )
            request.fetchLimit = 2

            let rows = try context.fetch(request)
            guard let row = rows.first else { return nil }
            guard rows.count == 1 else { throw CarbsStorageError.ambiguousMealHandle(handle) }
            guard let id = row.id, let date = row.date else { return nil }
            return (
                row.objectID,
                MealSnapshot(
                    id: id,
                    fpuID: row.fpuID,
                    date: date,
                    carbs: Decimal(row.carbs),
                    fat: Decimal(row.fat),
                    protein: Decimal(row.protein),
                    note: row.note
                )
            )
        }
    }

    func getCarbsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment] {
        let context = makeContext()
        context.name = "getCarbsNotYetUploadedToNightscout"
        return try await CoreDataStack.shared.fetchAndMap(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate.carbsNotYetUploadedToNightscout,
            key: "date",
            ascending: true,
            fetchLimit: UploadBacklog.maxRowsPerPass
        ) { carbEntries in
            carbEntries.map { result in
                NightscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .nsCarbCorrection,
                    createdAt: result.date,
                    enteredBy: CarbsEntry.local,
                    bolus: nil,
                    insulin: nil,
                    notes: result.note,
                    carbs: Decimal(result.carbs),
                    fat: Decimal(result.fat),
                    protein: Decimal(result.protein),
                    foodType: result.note,
                    targetTop: nil,
                    targetBottom: nil,
                    id: result.id?.uuidString,
                    fpuID: result.fpuID?.uuidString
                )
            }
        }
    }

    func getFPUsNotYetUploadedToNightscout() async throws -> [NightscoutTreatment] {
        let context = makeContext()
        context.name = "getFPUsNotYetUploadedToNightscout"
        return try await CoreDataStack.shared.fetchAndMap(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate.fpusNotYetUploadedToNightscout,
            key: "date",
            ascending: true,
            fetchLimit: UploadBacklog.maxRowsPerPass
        ) { fpuEntries in
            fpuEntries.map { result in
                NightscoutTreatment(
                    duration: nil,
                    rawDuration: nil,
                    rawRate: nil,
                    absolute: nil,
                    rate: nil,
                    eventType: .nsCarbCorrection,
                    createdAt: result.date,
                    enteredBy: CarbsEntry.local,
                    bolus: nil,
                    insulin: nil,
                    notes: result.note,
                    carbs: Decimal(result.carbs),
                    fat: Decimal(result.fat),
                    protein: Decimal(result.protein),
                    foodType: result.note,
                    targetTop: nil,
                    targetBottom: nil,
                    id: result.fpuID?.uuidString,
                    fpuID: result.fpuID?.uuidString
                )
            }
        }
    }

    func getCarbsNotYetUploadedToHealth() async throws -> [CarbsEntry] {
        let context = makeContext()
        context.name = "getCarbsNotYetUploadedToHealth"
        return try await CoreDataStack.shared.fetchAndMap(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate.carbsNotYetUploadedToHealth,
            key: "date",
            ascending: true,
            fetchLimit: UploadBacklog.maxRowsPerPass
        ) { carbEntries in
            carbEntries.map { result in
                CarbsEntry(
                    id: result.id?.uuidString,
                    createdAt: result.date ?? Date(),
                    actualDate: result.date,
                    carbs: Decimal(result.carbs),
                    fat: Decimal(result.fat),
                    protein: Decimal(result.protein),
                    note: result.note,
                    enteredBy: CarbsEntry.local,
                    isFPU: result.isFPU,
                    fpuID: result.fpuID?.uuidString
                )
            }
        }
    }

    func getCarbsNotYetUploadedToTidepool() async throws -> [CarbsEntry] {
        let context = makeContext()
        context.name = "getCarbsNotYetUploadedToTidepool"
        return try await CoreDataStack.shared.fetchAndMap(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate.carbsNotYetUploadedToTidepool,
            key: "date",
            ascending: true,
            fetchLimit: UploadBacklog.maxRowsPerPass
        ) { carbEntries in
            carbEntries.map { result in
                CarbsEntry(
                    id: result.id?.uuidString,
                    createdAt: result.date ?? Date(),
                    actualDate: result.date,
                    carbs: Decimal(result.carbs),
                    fat: nil,
                    protein: nil,
                    note: result.note,
                    enteredBy: CarbsEntry.local,
                    isFPU: nil,
                    fpuID: nil
                )
            }
        }
    }
}

/// Runs operations one at a time in submission order, including across suspension points.
private actor SerialStoreQueue {
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping () async throws -> Void) async throws {
        let previous = tail
        let task = Task {
            await previous?.value
            try await operation()
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}
