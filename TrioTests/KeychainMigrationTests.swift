import Foundation
import Testing

@testable import Trio

@Suite("Keychain Migration Tests", .serialized) struct KeychainMigrationTests {
    private let service = "KeychainMigrationTests-\(UUID().uuidString)"

    /// A keychain writing the way earlier Trio versions did, on a scratch service.
    private func legacyKeychain(synchronizable: Bool) -> BaseKeychain {
        BaseKeychain(serviceName: service, synchronizable: synchronizable, accessibilityLevel: .afterFirstUnlock)
    }

    @Test("New items stay on this device") func defaults() throws {
        let keychain = BaseKeychain(serviceName: service)
        defer { _ = keychain.removeAllKeys() }
        try (keychain.setValue("value", forKey: "k") as Result<Void, KeychainError>).get()
        #expect(try keychain.accessibilityOfKey("k").get() == .afterFirstUnlockThisDeviceOnly)
        #expect(BaseKeychain.Config.defaultSynchronizable == false)
    }

    @Test("A local item from an earlier version becomes device-only and stays readable") func localItem() throws {
        let legacy = legacyKeychain(synchronizable: false)
        defer { _ = legacy.removeAllKeys() }
        try (legacy.setValue("https://ns.example.test", forKey: "nightscoutURL") as Result<Void, KeychainError>).get()

        let keychain = BaseKeychain(serviceName: service)
        #expect(keychain.migrateLegacyItems())
        #expect(try keychain.getValue(String.self, forKey: "nightscoutURL").get() == "https://ns.example.test")
        #expect(try keychain.accessibilityOfKey("nightscoutURL").get() == .afterFirstUnlockThisDeviceOnly)
        // running again changes nothing
        #expect(keychain.migrateLegacyItems())
        #expect(try keychain.getValue(String.self, forKey: "nightscoutURL").get() == "https://ns.example.test")
    }

    @Test("An iCloud-synced item from an earlier version becomes a local item") func syncedItem() throws {
        let legacy = legacyKeychain(synchronizable: true)
        defer { _ = legacy.removeAllKeys() }
        // The test host may not be allowed to write synced items; then there is nothing to migrate.
        guard case .success = legacy.setValue("synced-secret", forKey: "secret") as Result<Void, KeychainError> else { return }

        let keychain = BaseKeychain(serviceName: service)
        #expect(keychain.migrateLegacyItems())
        #expect(try keychain.getValue(String.self, forKey: "secret").get() == "synced-secret")
        // the synced copy is gone
        #expect(try legacy.getValue(String.self, forKey: "secret").get() == nil)
    }

    @Test("The remote control secret moves from UserDefaults to the Keychain") func remoteSecret() throws {
        let keychain = BaseKeychain(serviceName: service)
        defer { _ = keychain.removeAllKeys() }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("legacy-shared-secret", forKey: RemoteControlSecretStore.key)

        #expect(RemoteControlSecretStore.secret(keychain: keychain, defaults: defaults) == "legacy-shared-secret")
        #expect(defaults.string(forKey: RemoteControlSecretStore.key) == nil)
        #expect(try keychain.getValue(String.self, forKey: RemoteControlSecretStore.key).get() == "legacy-shared-secret")

        // later reads come from the Keychain alone
        #expect(RemoteControlSecretStore.secret(keychain: keychain, defaults: defaults) == "legacy-shared-secret")
        RemoteControlSecretStore.setSecret("new-shared-secret", keychain: keychain)
        #expect(RemoteControlSecretStore.secret(keychain: keychain, defaults: defaults) == "new-shared-secret")
        #expect(defaults.string(forKey: RemoteControlSecretStore.key) == nil)
    }
}
