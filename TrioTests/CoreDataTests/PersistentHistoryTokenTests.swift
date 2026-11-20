import Combine
import CoreData
import Foundation
import Testing

@testable import Trio

/// The saved persistent history token can come from a store the stack no longer has. Fetching history after it then
/// fails with "Unable to find stores referenced in History Token" on every attempt, so no change reached the view
/// context or the change publishers until the app was restarted with a fresh token.
@Suite("Persistent History Token Tests", .serialized) struct PersistentHistoryTokenTests {
    @Test("A token from another store is replaced and changes reach observers again") func tokenFromAnotherStore() async throws {
        let otherStack = try await CoreDataStack.createForTests()
        let stack = try await CoreDataStack.createForTests()

        // A token that names the other store
        let otherContext = otherStack.newTaskContext()
        try await otherContext.perform {
            let row = GlucoseStored(context: otherContext)
            row.id = UUID()
            row.date = Date()
            try otherContext.save()
        }
        let foreignToken = try #require(
            otherStack.persistentContainer.persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: nil)
        )

        let id = UUID()
        let received = HistoryChangeFlag()
        let subscription = stack.entityChangePublisher.sink { _ in received.set() }
        defer { subscription.cancel() }

        UserDefaults.standard.lastHistoryToken = foreignToken
        let context = stack.newTaskContext()
        try await context.perform {
            let row = GlucoseStored(context: context)
            row.id = id
            row.date = Date()
            try context.save()
        }
        await stack.fetchPersistentHistory()

        // The merge and the publisher send run on the view context's queue
        let deadline = Date().addingTimeInterval(5)
        while !received.value, Date() < deadline {
            await stack.persistentContainer.viewContext.perform {}
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(received.value)
        let viewContext = stack.persistentContainer.viewContext
        let found = await viewContext.perform {
            let request = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return (try? viewContext.count(for: request)) ?? 0
        }
        #expect(found == 1)
    }
}

private final class HistoryChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
