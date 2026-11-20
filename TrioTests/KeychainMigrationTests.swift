import Foundation
import Security
import Testing

@testable import Trio

/// Whether this test host may write iCloud-synced Keychain items. Some simulator hosts can't; the synced-item tests
/// are then reported as skipped rather than passing without checking anything.
private let canWriteSyncedItems: Bool = {
    let service = "KeychainSyncProbe-\(UUID().uuidString)"
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: Data("probe".utf8),
        kSecAttrSynchronizable as String: kCFBooleanTrue as Any
    ]
    var add = query
    add[kSecValueData as String] = Data("probe".utf8)
    let status = SecItemAdd(add as CFDictionary, nil)
    SecItemDelete(query as CFDictionary)
    return status == errSecSuccess
}()

@Suite("Keychain Compatibility Tests", .serialized) struct KeychainMigrationTests {
    private let service = "KeychainCompatibilityTests-\(UUID().uuidString)"

    /// A keychain writing the way earlier Trio versions did (iCloud-synced, plain "after first unlock").
    private var legacy: BaseKeychain {
        BaseKeychain(serviceName: service, synchronizable: true, accessibilityLevel: .afterFirstUnlock)
    }

    private var current: BaseKeychain { BaseKeychain(serviceName: service) }

    /// Raw count of items for `key` with the given synchronizable flag, bypassing BaseKeychain.
    private func count(_ key: String, synchronizable: Bool) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Data(key.utf8),
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return 0 }
        return (result as? [[String: Any]])?.count ?? 0
    }

    private func cleanUp() {
        _ = current.removeAllKeys()
    }

    @Test("New items stay on this device") func defaults() throws {
        defer { cleanUp() }
        try (current.setValue("value", forKey: "k") as Result<Void, KeychainError>).get()
        #expect(try current.accessibilityOfKey("k").get() == .afterFirstUnlockThisDeviceOnly)
        #expect(count("k", synchronizable: false) == 1)
        #expect(count("k", synchronizable: true) == 0)
    }

    @Test("A local item from an earlier version is read as is, and moves to device-only when rewritten") func localLegacyItem()
        throws
    {
        defer { cleanUp() }
        let oldLocal = BaseKeychain(serviceName: service, synchronizable: false, accessibilityLevel: .afterFirstUnlock)
        try (oldLocal.setValue("https://ns.example.test", forKey: "url") as Result<Void, KeychainError>).get()

        #expect(try current.getValue(String.self, forKey: "url").get() == "https://ns.example.test")
        try (current.setValue("https://new.example.test", forKey: "url") as Result<Void, KeychainError>).get()
        #expect(try current.getValue(String.self, forKey: "url").get() == "https://new.example.test")
        #expect(try current.accessibilityOfKey("url").get() == .afterFirstUnlockThisDeviceOnly)
        #expect(count("url", synchronizable: false) == 1)
    }

    @Test("A synced-only item from an earlier version is read", .enabled(if: canWriteSyncedItems, "host can't write synced items"))
    func syncedOnlyItem() throws {
        defer { cleanUp() }
        try (legacy.setValue("synced-secret", forKey: "secret") as Result<Void, KeychainError>).get()
        #expect(try current.getValue(String.self, forKey: "secret").get() == "synced-secret")
        #expect(try current.hasValue(forKey: "secret").get())
    }

    @Test(
        "Writing never deletes the synced copy, and the newer of the two is read",
        .enabled(if: canWriteSyncedItems, "host can't write synced items")
    ) func localAndSynced() throws {
        defer { cleanUp() }
        try (legacy.setValue("old", forKey: "secret") as Result<Void, KeychainError>).get()
        Thread.sleep(forTimeInterval: 1.1) // modification dates have one-second resolution
        try (current.setValue("new", forKey: "secret") as Result<Void, KeychainError>).get()

        #expect(count("secret", synchronizable: true) == 1, "synced copy must survive for other devices")
        #expect(count("secret", synchronizable: false) == 1)
        #expect(try current.getValue(String.self, forKey: "secret").get() == "new")

        // e.g. re-entered on an older build afterwards: the synced copy is now the newer one
        Thread.sleep(forTimeInterval: 1.1)
        try (legacy.setValue("re-entered", forKey: "secret") as Result<Void, KeychainError>).get()
        #expect(try current.getValue(String.self, forKey: "secret").get() == "re-entered")
    }

    @Test(
        "An explicit removal deletes every copy",
        .enabled(if: canWriteSyncedItems, "host can't write synced items")
    ) func removeDeletesAll() throws {
        try (legacy.setValue("old", forKey: "secret") as Result<Void, KeychainError>).get()
        try (current.setValue("new", forKey: "secret") as Result<Void, KeychainError>).get()
        try (current.removeObject(forKey: "secret") as Result<Void, KeychainError>).get()
        #expect(count("secret", synchronizable: true) == 0)
        #expect(count("secret", synchronizable: false) == 0)
        #expect(try current.getValue(String.self, forKey: "secret").get() == nil)
    }

    @Test("The newer item wins, the local one on a tie") func preference() {
        let older = Date(timeIntervalSinceReferenceDate: 1000)
        let newer = Date(timeIntervalSinceReferenceDate: 2000)
        func item(_ value: String, synced: Bool, modified: Date?) -> [String: Any] {
            var item: [String: Any] = [
                kSecValueData as String: Data(value.utf8),
                kSecAttrSynchronizable as String: NSNumber(value: synced)
            ]
            item[kSecAttrModificationDate as String] = modified
            return item
        }
        func value(_ items: [[String: Any]]) -> String? {
            (BaseKeychain.preferred(items)?[kSecValueData as String] as? Data).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(value([item("local", synced: false, modified: older), item("synced", synced: true, modified: newer)]) == "synced")
        #expect(value([item("synced", synced: true, modified: older), item("local", synced: false, modified: newer)]) == "local")
        #expect(value([item("synced", synced: true, modified: newer), item("local", synced: false, modified: newer)]) == "local")
        #expect(value([item("local", synced: false, modified: nil), item("synced", synced: true, modified: nil)]) == "local")
        #expect(value([]) == nil)

        // a synced copy dated in the future (another device's clock runs ahead) doesn't beat the local one
        let now = Date(timeIntervalSinceReferenceDate: 3000)
        let future = Date(timeIntervalSinceReferenceDate: 9000)
        let local = item("local", synced: false, modified: older)
        let skewed = item("synced", synced: true, modified: future)
        #expect(
            (BaseKeychain.preferred([skewed, local], now: now)?[kSecValueData as String] as? Data)
                .map { String(decoding: $0, as: UTF8.self) } == "local"
        )
    }

    @Test("The remote control secret moves from UserDefaults to the Keychain") func remoteSecret() throws {
        defer { cleanUp() }
        let keychain = current
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("legacy-shared-secret", forKey: RemoteControlSecretStore.key)

        #expect(RemoteControlSecretStore.secret(keychain: keychain, defaults: defaults) == "legacy-shared-secret")
        #expect(defaults.string(forKey: RemoteControlSecretStore.key) == nil)
        #expect(try keychain.getValue(String.self, forKey: RemoteControlSecretStore.key).get() == "legacy-shared-secret")

        RemoteControlSecretStore.setSecret("new-shared-secret", keychain: keychain)
        #expect(RemoteControlSecretStore.secret(keychain: keychain, defaults: defaults) == "new-shared-secret")
        #expect(try RemoteControlSecretStore.read(keychain: keychain, defaults: defaults).get() == "new-shared-secret")
    }

    @Test("The remote secret falls back to UserDefaults when the Keychain can't be written, and errors stay errors")
    func remoteSecretFallback() throws {
        let failing = UnavailableKeychain()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("legacy-shared-secret", forKey: RemoteControlSecretStore.key)

        #expect(try RemoteControlSecretStore.read(keychain: failing, defaults: defaults).get() == "legacy-shared-secret")
        // kept for the next attempt
        #expect(defaults.string(forKey: RemoteControlSecretStore.key) == "legacy-shared-secret")

        defaults.removeObject(forKey: RemoteControlSecretStore.key)
        // unreadable is not "missing": callers must not generate a new secret
        guard case .failure = RemoteControlSecretStore.read(keychain: failing, defaults: defaults) else {
            Issue.record("expected a read failure")
            return
        }
    }
}

/// A Keychain that fails every call, like before the first unlock after a restart.
private final class UnavailableKeychain: Keychain {
    private let error = KeychainError.darwinError(errSecInteractionNotAllowed)

    func allKeys() -> Set<String> { [] }
    func hasValue(forKey _: String) -> Result<Bool, KeychainError> { .failure(error) }
    func accessibilityOfKey(_: String) -> Result<KeychainItemAccessibility, KeychainError> { .failure(error) }
    func getData(forKey _: String) -> Result<Data?, KeychainError> { .failure(error) }
    func getValue<T: Decodable>(_: T.Type, forKey _: String) -> Result<T?, KeychainError> { .failure(error) }
    func setData(_: Data, forKey _: String) -> Result<Void, KeychainError> { .failure(error) }
    func setValue<T: Encodable>(_: T?, forKey _: String) -> Result<Void, KeychainError> { .failure(error) }
    func removeObject(forKey _: String) -> Result<Void, KeychainError> { .failure(error) }
    func removeAllKeys() -> Result<Void, KeychainError> { .failure(error) }
    static func wipeKeychain() {}

    func getValue<T: Codable>(_: T.Type, forKey _: String) -> T? { nil }
    func getValue<T: Codable>(_: T.Type, forKey _: String, defaultValue: T?, reportError _: Bool) -> T? { defaultValue }
    func setValue<T: Codable>(_: T?, forKey _: String) {}
    func setValue<T: Codable>(_: T?, forKey _: String, reportError _: Bool) {}
}
