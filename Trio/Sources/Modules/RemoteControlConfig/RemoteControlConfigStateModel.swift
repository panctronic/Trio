import SwiftUI

extension RemoteControlConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Published var units: GlucoseUnits = .mgdL
        @Published var isTrioRemoteControlEnabled: Bool = false
        @Published var sharedSecret: String = ""
        @Injected() private var keychain: Keychain!

        override func subscribe() {
            units = settingsManager.settings.units
            isTrioRemoteControlEnabled = UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled")
            sharedSecret = RemoteControlSecretStore.secret(keychain: keychain) ?? generateInitialSharedSecret()

            $isTrioRemoteControlEnabled
                .receive(on: DispatchQueue.main)
                .sink { value in
                    UserDefaults.standard.set(value, forKey: "isTrioRemoteControlEnabled")
                }
                .store(in: &lifetime)

            $sharedSecret
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    guard let self else { return }
                    RemoteControlSecretStore.setSecret(value, keychain: self.keychain)
                }
                .store(in: &lifetime)
        }

        func generateNewSharedSecret() {
            let newSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
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
