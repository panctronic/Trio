import Foundation

enum SyncStatus {
    enum Config {}

    /// What the screen shows for one destination.
    struct DestinationRow: Identifiable, Equatable {
        let destination: SyncDestination
        let availability: SyncAvailability
        let record: SyncDestinationRecord
        /// `nil` while counting, when the destination is off, or when Core Data could not be read.
        let backlog: SyncBacklog?
        let health: SyncHealth
        /// The oldest waiting record leaves the upload window within a day.
        let isNearWindowLimit: Bool
        /// When the oldest waiting record leaves the upload window.
        let windowEnd: Date?

        var id: String { destination.id }
    }
}

protocol SyncStatusProvider {
    func availability(of destination: SyncDestination) -> SyncAvailability
    func backlog(for destination: SyncDestination) async -> SyncBacklog?
    func requestUpload(to destination: SyncDestination)
}
