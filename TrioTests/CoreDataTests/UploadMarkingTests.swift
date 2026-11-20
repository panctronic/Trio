import CoreData
import Foundation
import Testing

@testable import Trio

/// The "mark as uploaded" paths look rows up with `id IN %@`, and some pass ids of a different
/// type than the attribute: `String` ids (`BloodGlucose.id`, Tidepool sync identifiers) for UUID
/// attributes, and `UUID` ids (`NightscoutExercise.id`) for the String attribute of OverrideStored.
/// These tests pin down that the app's SQLite store matches both forms, on a file-backed store
/// configured like the app's, so a row can't stay unmarked and be re-sent forever.
@Suite("Upload Marking Tests", .serialized) struct UploadMarkingTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func makeContext() throws -> NSManagedObjectContext {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = NSPersistentContainer(
            name: "TrioCoreDataPersistentContainer",
            managedObjectModel: CoreDataStack.managedObjectModel
        )
        let description = try #require(container.persistentStoreDescriptions.first)
        description.url = directory.appendingPathComponent("Trio.sqlite")
        description.type = NSSQLiteStoreType
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container.newBackgroundContext()
    }

    /// Runs the same fetch-and-flag pattern as the upload managers, then re-reads the flag from the store.
    private func markAndReread<T: NSManagedObject>(
        _ type: T.Type,
        ids: [Any],
        flag: String,
        in context: NSManagedObjectContext
    ) throws -> [Bool] {
        try context.performAndWait {
            let request = NSFetchRequest<T>(entityName: String(describing: type))
            request.predicate = NSPredicate(format: "id IN %@", ids as NSArray)
            for row in try context.fetch(request) {
                row.setValue(true, forKey: flag)
            }
            try context.save()
            context.reset()

            let check = NSFetchRequest<T>(entityName: String(describing: type))
            return try context.fetch(check).map { ($0.value(forKey: flag) as? Bool) ?? false }
        }
    }

    @Test("Glucose rows are marked when matched by String ids") func glucoseByString() throws {
        let context = try makeContext()
        let id = UUID()
        try context.performAndWait {
            let row = GlucoseStored(context: context)
            row.id = id
            row.date = Date()
            row.isUploadedToNS = false
            row.isUploadedToHealth = false
            row.isUploadedToTidepool = false
            try context.save()
        }

        // Nightscout and Apple Health pass `BloodGlucose.id`, Tidepool `StoredGlucoseSample.syncIdentifier`.
        #expect(try markAndReread(GlucoseStored.self, ids: [id.uuidString], flag: "isUploadedToNS", in: context) == [true])
        #expect(try markAndReread(GlucoseStored.self, ids: [id.uuidString], flag: "isUploadedToHealth", in: context) == [true])
        #expect(try markAndReread(GlucoseStored.self, ids: [id.uuidString], flag: "isUploadedToTidepool", in: context) == [true])
    }

    @Test("Carb rows are marked when matched by String ids") func carbsByString() throws {
        let context = try makeContext()
        let id = UUID()
        try context.performAndWait {
            let row = CarbEntryStored(context: context)
            row.id = id
            row.date = Date()
            row.carbs = 20
            row.isUploadedToHealth = false
            row.isUploadedToTidepool = false
            try context.save()
        }

        // Apple Health and Tidepool pass `CarbsEntry.id`, a String.
        #expect(try markAndReread(CarbEntryStored.self, ids: [id.uuidString], flag: "isUploadedToHealth", in: context) == [true])
        #expect(try markAndReread(CarbEntryStored.self, ids: [id.uuidString], flag: "isUploadedToTidepool", in: context) == [true])
    }

    @Test("Override rows are marked when matched by UUID ids") func overridesByUUID() throws {
        let context = try makeContext()
        let id = UUID()
        try context.performAndWait {
            let row = OverrideStored(context: context)
            row.id = id.uuidString
            row.date = Date()
            row.isUploadedToNS = false
            try context.save()
        }

        // Nightscout passes `NightscoutExercise.id`, a UUID, for a String attribute.
        #expect(try markAndReread(OverrideStored.self, ids: [id], flag: "isUploadedToNS", in: context) == [true])
    }
}
