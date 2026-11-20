import Foundation

/// Where the Trio Remote Control shared secret lives. Anyone holding it can send remote commands (including boluses)
/// to this phone, so it is kept in the Keychain rather than in UserDefaults, which ends up in plain-text preference
/// files and unencrypted device backups.
enum RemoteControlSecretStore {
    /// Keychain key, and the UserDefaults key it was stored under before.
    static let key = "trioRemoteControlSharedSecret"

    /// The stored secret, or nil when none is set. Moves a secret left in UserDefaults into the Keychain first.
    static func secret(keychain: Keychain, defaults: UserDefaults = .standard) -> String? {
        migrateFromUserDefaults(keychain: keychain, defaults: defaults)
        guard case let .success(value) = keychain.getValue(String.self, forKey: key) as Result<String?, KeychainError>,
              let value, !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult static func setSecret(_ secret: String, keychain: Keychain) -> Bool {
        if case .failure = keychain.setValue(secret, forKey: key) as Result<Void, KeychainError> {
            warning(.remote, "Storing the remote control shared secret in the Keychain failed")
            return false
        }
        return true
    }

    /// Moves a secret stored by earlier versions from UserDefaults into the Keychain, and deletes it from UserDefaults
    /// only once the Keychain holds it. A UserDefaults value always replaces the Keychain one: after this has run once
    /// it can only reappear if an older Trio version ran in between, and then it is the secret that version used last.
    /// Safe to call repeatedly; when the Keychain can't be written (before the first unlock after a restart), the
    /// UserDefaults copy is left in place and the move is retried on the next call.
    static func migrateFromUserDefaults(keychain: Keychain, defaults: UserDefaults = .standard) {
        guard let legacy = defaults.string(forKey: key) else { return }
        if legacy.isEmpty || setSecret(legacy, keychain: keychain) {
            defaults.removeObject(forKey: key)
            info(.remote, "Moved the remote control shared secret from UserDefaults to the Keychain")
        }
    }
}
