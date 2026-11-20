import Foundation
import Testing

@testable import Trio

@Suite("Rejection Isolating Upload Tests") struct RejectionIsolatingUploadTests {
    private struct Rejected: Error {}
    private struct Offline: Error {}

    private actor Log {
        private(set) var requests: [[Int]] = []
        private(set) var accepted: [Int] = []
        private(set) var rejected: [Int] = []
        func request(_ items: [Int]) { requests.append(items) }
        func accept(_ items: [Int]) { accepted += items }
        func reject(_ items: [Int]) { rejected += items }
    }

    private func upload(
        _ items: [Int],
        chunkSize: Int = 10,
        log: Log,
        fails: @escaping ([Int]) -> Error?
    ) async throws {
        try await RejectionIsolatingUpload.run(
            items,
            chunkSize: chunkSize,
            isRejection: { $0 is Rejected },
            send: { batch in
                await log.request(batch)
                if let error = fails(batch) { throw error }
            },
            accepted: { await log.accept($0) },
            rejected: { refused, _ in await log.reject(refused) }
        )
    }

    @Test("A refused item is isolated and the rest is uploaded") func isolatesRefusedItem() async throws {
        let log = Log()
        try await upload(Array(0 ..< 20), log: log) { $0.contains(3) ? Rejected() : nil }

        #expect(await log.rejected == [3])
        #expect(await log.accepted.sorted() == Array(0 ..< 20).filter { $0 != 3 })
    }

    @Test("A refused item at the front doesn't block newer items") func refusedFirstItem() async throws {
        let log = Log()
        try await upload(Array(0 ..< 4), chunkSize: 4, log: log) { $0.contains(0) ? Rejected() : nil }

        #expect(await log.rejected == [0])
        #expect(await log.accepted.sorted() == [1, 2, 3])
    }

    @Test("Nothing is dropped when the service refuses everything") func refusesEverything() async {
        let log = Log()
        await #expect(throws: Rejected.self) {
            try await upload(Array(0 ..< 100), log: log) { _ in Rejected() }
        }
        #expect(await log.rejected.isEmpty)
        #expect(await log.accepted.isEmpty)
        // gives up after a few single-item rejections instead of trying every item
        #expect(await log.requests.count < 20)
    }

    @Test("Other errors stop the upload without dropping anything") func offlineStops() async {
        let log = Log()
        await #expect(throws: Offline.self) {
            try await upload(Array(0 ..< 30), log: log) { $0.contains(15) ? Offline() : nil }
        }
        #expect(await log.accepted == Array(0 ..< 10))
        #expect(await log.rejected.isEmpty)
        #expect(await log.requests.count == 2)
    }

    @Test("Nightscout errors are classified") func nightscoutClassification() {
        #expect(UploadRejection.isNightscoutRejection(NightscoutAPI.Error.badStatusCode(400)))
        #expect(UploadRejection.isNightscoutRejection(NightscoutAPI.Error.badStatusCode(413)))
        #expect(!UploadRejection.isNightscoutRejection(NightscoutAPI.Error.badStatusCode(401)))
        #expect(!UploadRejection.isNightscoutRejection(NightscoutAPI.Error.badStatusCode(404)))
        #expect(!UploadRejection.isNightscoutRejection(NightscoutAPI.Error.badStatusCode(500)))
        #expect(!UploadRejection.isNightscoutRejection(URLError(.notConnectedToInternet)))
    }
}
