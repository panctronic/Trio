import Foundation

struct AsyncTimeoutError: LocalizedError, Equatable {
    let seconds: TimeInterval

    var errorDescription: String? {
        String(localized: "No answer within \(Int(seconds)) seconds.")
    }
}

/// Returns the result of `operation`, or throws `AsyncTimeoutError` once `seconds` have passed without one.
///
/// For work that may never finish, such as a pump command whose callback never comes: on timeout the caller goes on,
/// while `operation` keeps running in the background (it cannot be cancelled) and its late result is dropped. Only use it
/// where carrying on without the result is safe.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable() async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = ResumeOnce(continuation)
        Task {
            do {
                once.resume(with: .success(try await operation()))
            } catch {
                once.resume(with: .failure(error))
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            once.resume(with: .failure(AsyncTimeoutError(seconds: seconds)))
        }
    }
}

/// Resumes a continuation at most once; later results are dropped.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
