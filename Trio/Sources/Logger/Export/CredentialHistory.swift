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
        return byKey.values
            .filter { now.timeIntervalSince($0.lastSeen) <= keepFor }
            .sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.value < $1.value }
            .prefix(maxEntries)
            .map { $0 }
    }

    static func load(keychain: Keychain) -> [Entry] {
        guard case let .success(entries?) = keychain.getValue([Entry].self, forKey: keychainKey) as Result<[Entry]?, KeychainError>
        else { return [] }
        return entries
    }

    /// Remembers the credentials in use now. Writes only when something changed.
    static func record(_ current: [Redactor.ExactValue], keychain: Keychain, now: Date = Date()) {
        let stored = load(keychain: keychain)
        let updated = merged(stored, with: current, now: now)
        guard updated != stored else { return }
        if case .failure = keychain.setValue(updated, forKey: keychainKey) as Result<Void, KeychainError> {
            warning(.storage, "Storing recent credentials for log redaction failed")
        }
    }

    /// The remembered values that may still appear in retained logs.
    static func recentValues(keychain: Keychain, now: Date = Date()) -> [Redactor.ExactValue] {
        merged(load(keychain: keychain), with: [], now: now).compactMap { entry in
            Redactor.Kind(rawValue: entry.kind).map { Redactor.ExactValue(value: entry.value, kind: $0) }
        }
    }
}
