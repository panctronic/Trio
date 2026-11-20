import Foundation
import HealthKit

/// Uploads records in chunks so that a record a service refuses can't hold back the records
/// queued behind it.
///
/// Upload batches are fetched with a per-pass limit, so a chunk that keeps failing would otherwise be
/// sent again on every pass and block everything after it until it leaves the upload window. When the
/// service rejects a chunk as invalid (`isRejection`), the chunk is split in halves until the refused
/// records are isolated; the others are uploaded as usual. Refused records are handed to `rejected`
/// only if the service accepted something else in the same run, which shows that it takes data at
/// all, so a server that refuses everything doesn't make records get dropped. Any other error, such
/// as no network or an expired login, ends the run and is rethrown, and the batch is retried later.
enum RejectionIsolatingUpload {
    /// Refused single records tolerated before the run ends when nothing has been accepted yet.
    static let maxRejectedBeforeAnyAccepted = 3

    static func run<Item>(
        _ items: [Item],
        chunkSize: Int,
        isRejection: (Error) -> Bool,
        send: ([Item]) async throws -> Void,
        accepted: ([Item]) async -> Void,
        rejected: ([Item], Error) async -> Void
    ) async throws {
        var acceptedAny = false
        var refused: [Item] = []
        var lastRejection: Error?

        func sendIsolating(_ batch: [Item]) async throws {
            do {
                try await send(batch)
            } catch where isRejection(error) {
                lastRejection = error
                guard batch.count > 1 else {
                    refused.append(contentsOf: batch)
                    if !acceptedAny, refused.count > maxRejectedBeforeAnyAccepted { throw error }
                    return
                }
                let middle = batch.count / 2
                try await sendIsolating(Array(batch[..<middle]))
                try await sendIsolating(Array(batch[middle...]))
                return
            }
            acceptedAny = true
            await accepted(batch)
        }

        for chunk in items.chunks(ofCount: max(1, chunkSize)) {
            try await sendIsolating(chunk)
        }

        guard let lastRejection, refused.isNotEmpty else { return }
        if acceptedAny {
            await rejected(refused, lastRejection)
        } else {
            throw lastRejection
        }
    }
}

extension RejectionIsolatingUpload {
    /// Sends `items` as one request. If the service rejects it as invalid, sends it in halves instead and
    /// drops the refused items with a log line. Throws only when nothing could be sent, so on success the
    /// caller marks all `items` as handled.
    static func sendDroppingRejected<Item>(
        _ items: [Item],
        label: String,
        category: Logger.Category,
        isRejection: (Error) -> Bool,
        send: ([Item]) async throws -> Void
    ) async throws {
        guard items.isNotEmpty else {
            try await send(items)
            return
        }
        try await run(
            items,
            chunkSize: items.count,
            isRejection: isRejection,
            send: send,
            accepted: { _ in },
            rejected: { refused, error in
                warning(category, "Refused \(refused.count) \(label), not retrying them", error: error)
            }
        )
    }
}

enum UploadRejection {
    /// Nightscout refused the data itself (HTTP 4xx other than authentication, not found, timeout and
    /// rate limiting), or it could not be encoded. Sending it unchanged again can't succeed.
    static func isNightscoutRejection(_ error: Error) -> Bool {
        if error is EncodingError { return true }
        guard case let NightscoutAPI.Error.badStatusCode(code) = error else { return false }
        return (400 ..< 500).contains(code) && ![401, 403, 404, 408, 429].contains(code)
    }

    /// Tidepool answered that the request was malformed (HTTP 400). TidepoolKit's `TError` isn't
    /// visible to this target, so the case is recognised by name.
    static func isTidepoolRejection(_ error: Error) -> Bool {
        guard String(describing: type(of: error)) == "TError",
              let label = Mirror(reflecting: error).children.first?.label
        else { return false }
        return label == "requestMalformed" || label == "requestMalformedJSON"
    }

    /// Apple Health refused a sample as invalid.
    static func isAppleHealthRejection(_ error: Error) -> Bool {
        (error as? HealthKit.HKError)?.code == .errorInvalidArgument
    }
}
