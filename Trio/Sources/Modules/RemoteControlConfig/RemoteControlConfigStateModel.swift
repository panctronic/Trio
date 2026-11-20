import SwiftUI

extension RemoteControlConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Published var units: GlucoseUnits = .mgdL
        @Published var isTrioRemoteControlEnabled: Bool = false
        @Published var sharedSecret: String = ""
        /// The Keychain couldn't be read; the shown secret is not the stored one and must not be saved over it.
        @Published var isSecretUnavailable = false
        @Injected() private var keychain: Keychain!

        override func subscribe() {
            units = settingsManager.settings.units
            isTrioRemoteControlEnabled = UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled")
            switch RemoteControlSecretStore.read(keychain: keychain) {
            case let .success(secret?):
                sharedSecret = secret
            case .success(nil):
                // definitely none stored yet
                sharedSecret = generateInitialSharedSecret()
            case let .failure(error):
                // Never replace a secret we merely couldn't read: the follower would stop being able to send.
                // Leave the field empty and don't save it (see the sink below).
                warning(.remote, "Reading the remote control shared secret failed", error: error)
                isSecretUnavailable = true
            }

            $isTrioRemoteControlEnabled
                .receive(on: DispatchQueue.main)
                .sink { value in
                    UserDefaults.standard.set(value, forKey: "isTrioRemoteControlEnabled")
                }
                .store(in: &lifetime)

            $sharedSecret
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    guard let self, !self.isSecretUnavailable || !value.isEmpty else { return }
                    self.isSecretUnavailable = false
                    RemoteControlSecretStore.setSecret(value, keychain: self.keychain)
                }
                .store(in: &lifetime)
        }

        func generateNewSharedSecret() {
            let newSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            isSecretUnavailable = false
            sharedSecret = newSecret
            RemoteControlSecretStore.setSecret(newSecret, keychain: keychain)
        }

        private func generateInitialSharedSecret() -> String {
            let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            RemoteControlSecretStore.setSecret(secret, keychain: keychain)
            return secret
        }
    }
}

extension RemoteControlConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
