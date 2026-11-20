import os
import UIKit

/// Ends a background task safely and ensures it is not called multiple times.
///
/// - Parameter taskID: The background task identifier to be ended.
func endBackgroundTaskSafely(_ taskID: inout UIBackgroundTaskIdentifier, taskName: String = "Unnamed Task") {
    guard taskID != .invalid else {
        debug(.lifecycle, "Background task '\(taskName)' already ended")
        return
    }
    defer { taskID = .invalid }

    // The expiration handler already ended it; ending it twice only produces a system warning.
    guard !BackgroundTaskRegistry.shared.consumeExpired(taskID) else {
        debug(.lifecycle, "Background task '\(taskName)' already ended on expiry")
        return
    }
    UIApplication.shared.endBackgroundTask(taskID)
    debug(.lifecycle, "Background task '\(taskName)' ended")
}

/// Starts a background task and handles its expiration safely.
///
/// iOS terminates the app if a background task is still running when its time runs out, so the
/// expiration handler must end it. The handler is created before `beginBackgroundTask` returns the
/// identifier, so the identifier is passed in through a shared box rather than captured by value
/// (a value capture would always hold `.invalid` and the task would never be ended).
///
/// - Parameter name: The background task name.
func startBackgroundTask(withName name: String) -> UIBackgroundTaskIdentifier {
    let box = BackgroundTaskIDBox()
    let taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
        // Runs on the main thread; the task has to be ended before this returns.
        box.expire { expiredID in
            BackgroundTaskRegistry.shared.markExpired(expiredID)
            UIApplication.shared.endBackgroundTask(expiredID)
            warning(.lifecycle, "Background task '\(name)' expired")
        }
    }
    box.set(taskID) { expiredID in
        // Expired before the identifier was even known: end it now.
        BackgroundTaskRegistry.shared.markExpired(expiredID)
        UIApplication.shared.endBackgroundTask(expiredID)
        warning(.lifecycle, "Background task '\(name)' expired")
    }

    debug(.lifecycle, "Background task '\(name)' started")
    return taskID
}

/// Hands the identifier returned by `beginBackgroundTask` to its own expiration handler.
final class BackgroundTaskIDBox: Sendable {
    private struct State {
        var taskID: UIBackgroundTaskIdentifier = .invalid
        var expired = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Records the identifier. If the expiration handler already ran, `onAlreadyExpired` ends it.
    func set(_ id: UIBackgroundTaskIdentifier, onAlreadyExpired: (UIBackgroundTaskIdentifier) -> Void) {
        let alreadyExpired = state.withLock { state in
            state.taskID = id
            return state.expired
        }
        if alreadyExpired, id != .invalid { onAlreadyExpired(id) }
    }

    /// Called from the expiration handler; runs `end` with the identifier once it is known.
    func expire(_ end: (UIBackgroundTaskIdentifier) -> Void) {
        let id = state.withLock { state in
            state.expired = true
            return state.taskID
        }
        if id != .invalid { end(id) }
    }
}

/// Identifiers ended by their expiration handler, so the owner's later
/// `endBackgroundTaskSafely` does not end them a second time.
final class BackgroundTaskRegistry: Sendable {
    static let shared = BackgroundTaskRegistry()
    private let expiredIDs = OSAllocatedUnfairLock(initialState: Set<UIBackgroundTaskIdentifier>())

    func markExpired(_ id: UIBackgroundTaskIdentifier) {
        _ = expiredIDs.withLock { $0.insert(id) }
    }

    /// Returns whether `id` was ended on expiry, forgetting it either way.
    func consumeExpired(_ id: UIBackgroundTaskIdentifier) -> Bool {
        expiredIDs.withLock { $0.remove(id) != nil }
    }
}
