import Foundation

/// Credentials Trio used recently, so a log export also redacts ones that have since been replaced.
///
/// The redactor matches exact values, and the current values only come from the live configuration. A Nightscout
/// secret or URL, Tidepool account or remote control secret that was changed in the last few days is no longer in
/// that configuration, but the retained logs still contain it. This keeps every value seen while it was current,
/// with the last time it was seen, in the Keychain (device-only, like the credentials themselves), and drops it once
/// the logs that could contain it have aged out.
enum CredentialHistory {
    struct Entry: Codable, Equatable {
        let value: String
        let kind: String
        var lastSeen: Date
    }

    static let keychainKey = "logRedaction.recentCredentials"
    /// Logs are kept for `LogRetentionPolicy.default.maxAge`; a day on top covers clock and pruning slack.
    static let keepFor: TimeInterval = LogRetentionPolicy.default.maxAge + 24 * 60 * 60
    /// Bound on stored values (each credential also stores its encoded forms); the least recently seen go first.
    static let maxEntries = 500
    /// Bound per kind, so values that churn (session tokens are `.token` and refresh often) can't push out a
    /// replaced password, Nightscout secret or account of another kind.
    static let maxEntriesPerKind = 100
    /// `lastSeen` is only refreshed this often, so a foreground transition doesn't rewrite the Keychain item.
    static let refreshInterval: TimeInterval = 60 * 60

    /// Adds `current` to `entries` (refreshing `lastSeen` of values already there once it is `refreshInterval` old),
    /// drops entries not seen within
    /// `keepFor`, and keeps at most `maxEntries`, most recently seen first.
    static func merged(_ entries: [Entry], with current: [Redactor.ExactValue], now: Date) -> [Entry] {
        var byKey: [String: Entry] = [:]
        for entry in entries {
            byKey[entry.kind + "|" + entry.value] = entry
        }
        for value in current {
            let key = value.kind.rawValue + "|" + value.value
            if let existing = byKey[key], now.timeIntervalSince(existing.lastSeen) < refreshInterval { continue }
            byKey[key] = Entry(value: value.value, kind: value.kind.rawValue, lastSeen: now)
        }
        let newestFirst: (Entry, Entry) -> Bool = {
            $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.value < $1.value
        }
        let kept = Dictionary(grouping: byKey.values.filter { now.timeIntervalSince($0.lastSeen) <= keepFor }, by: \.kind)
            .values
            .flatMap { $0.sorted(by: newestFirst).prefix(maxEntriesPerKind) }
        return Array(kept.sorted(by: newestFirst).prefix(maxEntries))
    }

    /// The stored history: empty when there is none yet, nil when it couldn't be read or decoded.
    static func load(keychain: Keychain) -> [Entry]? {
        switch keychain.getValue([Entry].self, forKey: keychainKey) as Result<[Entry]?, KeychainError> {
        case let .success(entries): return entries ?? []
        case .failure: return nil
        }
    }

    /// Remembers the credentials in use now. Writes only when something changed. When the Keychain can't be read
    /// (e.g. the device is locked) nothing is written, since that would replace the history with only the current
    /// values. A stored history that can't be decoded is useless, though, so it is replaced by a fresh one rather
    /// than blocking every later update.
    static func record(_ current: [Redactor.ExactValue], keychain: Keychain, now: Date = Date()) {
        let stored: [Entry]
        var replacesUnreadable = false
        switch keychain.getValue([Entry].self, forKey: keychainKey) as Result<[Entry]?, KeychainError> {
        case let .success(entries):
            stored = entries ?? []
        case .failure(.codingError):
            warning(.storage, "Recent credentials for log redaction couldn't be decoded; starting a new list")
            stored = []
            replacesUnreadable = true
        case .failure:
            warning(.storage, "Reading recent credentials for log redaction failed; not updating them")
            return
        }
        let updated = merged(stored, with: current, now: now)
        guard updated != stored || replacesUnreadable else { return }
        if case .failure = keychain.setValue(updated, forKey: keychainKey) as Result<Void, KeychainError> {
            warning(.storage, "Storing recent credentials for log redaction failed")
        }
    }

    /// The remembered values that may still appear in retained logs.
    static func recentValues(keychain: Keychain, now: Date = Date()) -> [Redactor.ExactValue] {
        merged(load(keychain: keychain) ?? [], with: [], now: now).compactMap { entry in
            Redactor.Kind(rawValue: entry.kind).map { Redactor.ExactValue(value: entry.value, kind: $0) }
        }
    }
}
