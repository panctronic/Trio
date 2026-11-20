import Foundation
import Testing

@testable import Trio

@Suite("Pending Deletion Queue Tests", .serialized) struct PendingDeletionQueueTests {
    /// Mutable clock shared with the queue under test.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(minutes: Double) { now += minutes * 60 }
    }

    private actor Calls {
        private(set) var ids: [String] = []
        func record(_ id: String) { ids.append(id) }
    }

    private let storage = BaseFileStorage()
    private let clock = Clock()
    private let file = "upload/test-pending-deletions-\(UUID().uuidString).json"

    private func makeQueue() -> PendingDeletionQueue {
        let clock = clock
        return PendingDeletionQueue(storage: storage, file: file, category: .storage, now: { clock.now })
    }

    private func deletion(_ id: String, kind: PendingRemoteDeletion.Kind = .carbs) -> PendingRemoteDeletion {
        PendingRemoteDeletion(kind: kind, id: id, date: clock.now, failedAt: clock.now)
    }

    @Test("Enqueued deletions persist and are deduplicated") func enqueuePersists() async {
        let queue = makeQueue()
        await queue.enqueue(deletion("a"))
        await queue.enqueue(deletion("a"))
        await queue.enqueue(deletion("a", kind: .insulin))
        await queue.enqueue(deletion("b"))

        // A new queue on the same file sees the same entries, as after an app restart.
        let reloaded = await makeQueue().pending
        #expect(reloaded.map(\.id) == ["a", "a", "b"])
        #expect(reloaded.map(\.kind) == [.carbs, .insulin, .carbs])
        storage.remove(file)
    }

    @Test("Entries are retried only after the back-off and removed on success") func drainOnSuccess() async {
        let queue = makeQueue()
        let calls = Calls()
        await queue.enqueue(deletion("a"))

        // Just failed: not due yet.
        await queue.retryDue { await calls.record($0.id); return true }
        #expect(await calls.ids.isEmpty)

        clock.advance(minutes: 5)
        await queue.retryDue { await calls.record($0.id); return true }
        #expect(await calls.ids == ["a"])
        #expect(await queue.pending.isEmpty)
    }

    @Test("A failed retry backs off exponentially") func backOff() async {
        let queue = makeQueue()
        let calls = Calls()
        await queue.enqueue(deletion("a"))

        clock.advance(minutes: 5)
        await queue.retryDue { await calls.record($0.id); return false }
        #expect(await queue.pending.first?.attempts == 2)

        // Second retry waits 10 minutes after the last attempt.
        clock.advance(minutes: 9)
        await queue.retryDue { await calls.record($0.id); return false }
        #expect(await calls.ids.count == 1)

        clock.advance(minutes: 1)
        await queue.retryDue { await calls.record($0.id); return true }
        #expect(await calls.ids.count == 2)
        #expect(await queue.pending.isEmpty)
    }

    @Test("Gives up after the maximum number of attempts") func giveUpAfterAttempts() async {
        let queue = makeQueue()
        let calls = Calls()
        await queue.enqueue(deletion("a"))

        // Advance by exactly each back-off; the attempt limit is reached before the age limit.
        while let entry = await queue.pending.first {
            let delay = min(
                PendingDeletionQueue.initialRetryDelay * pow(2, Double(entry.attempts - 1)),
                PendingDeletionQueue.maxRetryDelay
            )
            clock.advance(minutes: delay / 60)
            await queue.retryDue { await calls.record($0.id); return false }
        }
        #expect(await calls.ids.count == PendingDeletionQueue.maxAttempts - 1)
    }

    @Test("Gives up on entries older than the age limit without retrying") func giveUpAfterAge() async {
        let queue = makeQueue()
        let calls = Calls()
        await queue.enqueue(deletion("old"))

        clock.advance(minutes: PendingDeletionQueue.maxAge / 60 + 1)
        await queue.retryDue { await calls.record($0.id); return true }
        #expect(await calls.ids.isEmpty)
        #expect(await queue.pending.isEmpty)
    }

    @Test("Deletions enqueued during a retry are kept") func enqueueDuringRetry() async {
        let queue = makeQueue()
        await queue.enqueue(deletion("a"))
        clock.advance(minutes: 5)

        let late = deletion("b")
        await queue.retryDue { _ in
            await queue.enqueue(late)
            return true
        }
        #expect(await queue.pending.map(\.id) == ["b"])
        storage.remove(file)
    }
}
