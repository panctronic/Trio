import Foundation

/// Where the Trio Remote Control shared secret lives. Anyone holding it can send remote commands (including boluses)
/// to this phone, so it is kept in the Keychain rather than in UserDefaults, which ends up in plain-text preference
/// files and unencrypted device backups.
enum RemoteControlSecretStore {
    /// Keychain key, and the UserDefaults key it was stored under before.
    static let key = "trioRemoteControlSharedSecret"

    /// The stored secret: `.success(nil)` only when there is definitely none, `.failure` when the Keychain couldn't
    /// be read (for example before the first unlock after a restart), so callers never mistake an error for "not
    /// set". A secret still in UserDefaults is moved into the Keychain first; if that move fails, the UserDefaults
    /// value is returned and the move is retried on the next read.
    static func read(keychain: Keychain, defaults: UserDefaults = .standard) -> Result<String?, KeychainError> {
        if let legacy = defaults.string(forKey: key) {
            if legacy.isEmpty {
                defaults.removeObject(forKey: key)
            } else {
                if setSecret(legacy, keychain: keychain) {
                    defaults.removeObject(forKey: key)
                    info(.remote, "Moved the remote control shared secret from UserDefaults to the Keychain")
                }
                // A UserDefaults value only exists if this build never moved it, or an older build wrote it since;
                // either way it is the one in use.
                return .success(legacy)
            }
        }
        return (keychain.getValue(String.self, forKey: key) as Result<String?, KeychainError>)
            .map { value in value.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// The stored secret, or nil when there is none or it can't be read right now.
    static func secret(keychain: Keychain, defaults: UserDefaults = .standard) -> String? {
        (try? read(keychain: keychain, defaults: defaults).get()) ?? nil
    }

    @discardableResult static func setSecret(_ secret: String, keychain: Keychain) -> Bool {
        if case .failure = keychain.setValue(secret, forKey: key) as Result<Void, KeychainError> {
            warning(.remote, "Storing the remote control shared secret in the Keychain failed")
            return false
        }
        return true
    }
}
