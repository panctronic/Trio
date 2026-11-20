import Combine
import Foundation
import Observation

extension SyncStatus {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var tracker: SyncStatusTracker!

        private(set) var rows: [DestinationRow] = []
        /// Destinations whose "Retry now" was tapped a moment ago.
        private(set) var retryRequested: Set<SyncDestination> = []
        /// Reference time for the relative dates on screen.
        private(set) var now = Date()

        @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
        @ObservationIgnored private var refreshTask: Task<Void, Never>?

        /// How long "Retry now" stays disabled after a tap, and when the counts are re-read.
        static let retryFeedbackDelay: TimeInterval = 5

        /// The view calls `refresh()` when it appears.
        override func subscribe() {
            // Each recorded upload changes the counts too; coalesce bursts into one re-count.
            Foundation.NotificationCenter.default.publisher(for: SyncStatusTracker.didChange)
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
        }

        /// Re-reads the tracker and re-counts the backlogs (off the main thread).
        func refresh() {
            refreshTask?.cancel()
            refreshTask = Task { @MainActor [weak self] in
                guard let self, let provider = self.provider, let tracker = self.tracker else { return }
                let snapshot = tracker.snapshot
                var newRows: [DestinationRow] = []

                for destination in SyncDestination.allCases {
                    let availability = provider.availability(of: destination)
                    let backlog = availability == .off ? nil : await provider.backlog(for: destination)
                    guard !Task.isCancelled else { return }
                    newRows.append(Self.row(
                        destination: destination,
                        availability: availability,
                        record: snapshot[destination],
                        backlog: backlog,
                        now: Date()
                    ))
                }

                self.now = Date()
                self.rows = newRows
            }
        }

        func retry(_ destination: SyncDestination) {
            guard !retryRequested.contains(destination) else { return }
            provider.requestUpload(to: destination)
            retryRequested.insert(destination)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.retryFeedbackDelay * 1_000_000_000))
                self?.retryRequested.remove(destination)
                self?.refresh()
            }
        }

        static func row(
            destination: SyncDestination,
            availability: SyncAvailability,
            record: SyncDestinationRecord,
            backlog: SyncBacklog?,
            now: Date
        ) -> DestinationRow {
            let oldest = backlog?.oldestPending
            return DestinationRow(
                destination: destination,
                availability: availability,
                record: record,
                backlog: backlog,
                health: SyncStatusRules.classify(
                    destination: destination,
                    availability: availability,
                    record: record,
                    backlog: backlog,
                    now: now
                ),
                isNearWindowLimit: SyncStatusRules.isNearWindowLimit(oldestPending: oldest, destination: destination, now: now),
                windowEnd: oldest.map { SyncStatusRules.windowEnd(for: $0, destination: destination) }
            )
        }
    }
}
