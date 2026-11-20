import Foundation

/// A deletion that a remote service (Nightscout, Tidepool or Apple Health) did not accept and that
/// is retried on later upload passes, so a record deleted in Trio doesn't stay visible to followers.
struct PendingRemoteDeletion: JSON, Equatable {
    enum Kind: String, Codable {
        case carbs
        case insulin
        case glucose
        /// An Apple Health sample of type `sampleType`.
        case healthSample
    }

    let kind: Kind
    /// Identifier of the remote record (Nightscout `id`, Tidepool or Apple Health sync identifier).
    let id: String
    /// Extra values some services need to address or describe the record.
    var date: Date?
    var amount: Decimal?
    var enteredBy: String?
    var sampleType: String?

    /// When the deletion first failed.
    var queuedAt: Date
    var attempts: Int
    var lastAttemptAt: Date

    init(
        kind: Kind,
        id: String,
        date: Date? = nil,
        amount: Decimal? = nil,
        enteredBy: String? = nil,
        sampleType: String? = nil,
        failedAt: Date = Date()
    ) {
        self.kind = kind
        self.id = id
        self.date = date
        self.amount = amount
        self.enteredBy = enteredBy
        self.sampleType = sampleType
        queuedAt = failedAt
        attempts = 1
        lastAttemptAt = failedAt
    }

    func isSameRecord(as other: PendingRemoteDeletion) -> Bool {
        kind == other.kind && id == other.id && sampleType == other.sampleType
    }
}

/// Persistent retry queue for failed remote deletions, one file per service.
///
/// A failed deletion is enqueued with one attempt recorded. `retryDue(_:)` runs from the
/// service's upload passes and retries entries whose back-off has elapsed (5 min, doubling up to
/// 6 h). An entry is dropped once the service accepts it, after `maxAttempts` attempts, or when it
/// is older than `maxAge`.
actor PendingDeletionQueue {
    static let maxAttempts = 30
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let initialRetryDelay: TimeInterval = 5 * 60
    static let maxRetryDelay: TimeInterval = 6 * 60 * 60

    private let storage: FileStorage
    private let file: String
    private let category: Logger.Category
    private let now: () -> Date
    /// Entries being retried right now, so overlapping passes don't send the same deletion twice.
    private var inFlight: [PendingRemoteDeletion] = []

    init(storage: FileStorage, file: String, category: Logger.Category, now: @escaping () -> Date = { Date() }) {
        self.storage = storage
        self.file = file
        self.category = category
        self.now = now
    }

    var pending: [PendingRemoteDeletion] {
        load()
    }

    /// Records a deletion that just failed. A deletion already queued for the same record is kept as is.
    func enqueue(_ deletion: PendingRemoteDeletion) {
        var entries = load()
        guard !entries.contains(where: { $0.isSameRecord(as: deletion) }) else { return }
        entries.append(deletion)
        save(entries)
        debug(category, "Queued \(deletion.kind.rawValue) deletion \(deletion.id) for retry")
    }

    /// Retries the entries that are due, one at a time. `perform` returns `true` when the service
    /// accepted the deletion.
    func retryDue(_ perform: (PendingRemoteDeletion) async -> Bool) async {
        let entries = removeExpired(from: load())
        let due = entries.filter { entry in
            isDue(entry) && !inFlight.contains(where: { $0.isSameRecord(as: entry) })
        }

        for entry in due {
            inFlight.append(entry)
            let succeeded = await perform(entry)
            inFlight.removeAll { $0.isSameRecord(as: entry) }
            record(entry, succeeded: succeeded)
        }
    }

    // MARK: - Private

    private func isDue(_ entry: PendingRemoteDeletion) -> Bool {
        let exponent = Double(max(0, entry.attempts - 1))
        let delay = min(Self.initialRetryDelay * pow(2, exponent), Self.maxRetryDelay)
        return now().timeIntervalSince(entry.lastAttemptAt) >= delay
    }

    private func isExhausted(_ entry: PendingRemoteDeletion) -> Bool {
        entry.attempts >= Self.maxAttempts || now().timeIntervalSince(entry.queuedAt) > Self.maxAge
    }

    /// Drops entries that ran out of attempts or time, and persists the result if anything changed.
    private func removeExpired(from entries: [PendingRemoteDeletion]) -> [PendingRemoteDeletion] {
        let (expired, kept) = entries.reduce(into: ([PendingRemoteDeletion](), [PendingRemoteDeletion]())) { result, entry in
            if isExhausted(entry) { result.0.append(entry) } else { result.1.append(entry) }
        }
        guard expired.isNotEmpty else { return entries }
        for entry in expired {
            warning(
                category,
                "Giving up on \(entry.kind.rawValue) deletion \(entry.id) after \(entry.attempts) attempts"
            )
        }
        save(kept)
        return kept
    }

    /// Updates the stored entry after a retry. The file is re-read because entries may have been
    /// enqueued while the retry was suspended.
    private func record(_ entry: PendingRemoteDeletion, succeeded: Bool) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.isSameRecord(as: entry) }) else { return }
        if succeeded {
            entries.remove(at: index)
            debug(category, "Retried \(entry.kind.rawValue) deletion \(entry.id) succeeded")
        } else {
            entries[index].attempts += 1
            entries[index].lastAttemptAt = now()
            if isExhausted(entries[index]) {
                warning(
                    category,
                    "Giving up on \(entry.kind.rawValue) deletion \(entry.id) after \(entries[index].attempts) attempts"
                )
                entries.remove(at: index)
            }
        }
        save(entries)
    }

    private func load() -> [PendingRemoteDeletion] {
        storage.retrieve(file, as: [PendingRemoteDeletion].self) ?? []
    }

    private func save(_ entries: [PendingRemoteDeletion]) {
        if entries.isEmpty {
            storage.remove(file)
        } else {
            storage.save(entries, as: file)
        }
    }
}
