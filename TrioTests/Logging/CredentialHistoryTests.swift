import CryptoKit
import Foundation
import Testing

@testable import Trio

@Suite("Credential History Tests") struct CredentialHistoryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func values(url: String, secret: String) -> [Redactor.ExactValue] {
        var values = SensitiveValues()
        values.addNightscout(url: url, secret: secret)
        return values.values
    }

    @Test("A replaced Nightscout secret is still redacted while logs can contain it") func replacedSecret() {
        let old = values(url: "https://old-site.example.test", secret: "old synthetic secret")
        let new = values(url: "https://new-site.example.test", secret: "new synthetic secret")
        var history = CredentialHistory.merged([], with: old, now: now.addingTimeInterval(-3 * day))
        history = CredentialHistory.merged(history, with: new, now: now)

        var sensitive = SensitiveValues()
        sensitive.add(exact: new)
        sensitive.add(exact: history.compactMap { entry in
            Redactor.Kind(rawValue: entry.kind).map { Redactor.ExactValue(value: entry.value, kind: $0) }
        })
        let redactor = Redactor(exactValues: sensitive.values)
        let oldHash = Insecure.SHA1.hash(data: Data("old synthetic secret".utf8)).map { String(format: "%02x", $0) }.joined()

        #expect(redactor.redact("secret old synthetic secret") == "secret <api-secret>")
        #expect(redactor.redact("api-secret: \(oldHash)") == "api-secret: <api-secret>")
        #expect(redactor.redact("GET https://old-site.example.test/api") == "GET <nightscout-url>/api")
        #expect(redactor.redact("secret new synthetic secret") == "secret <api-secret>")
    }

    @Test("Values are dropped once the logs that could hold them have aged out") func pruning() {
        let old = values(url: "https://old-site.example.test", secret: "old synthetic secret")
        let history = CredentialHistory.merged([], with: old, now: now.addingTimeInterval(-CredentialHistory.keepFor - 1))
        #expect(CredentialHistory.merged(history, with: [], now: now).isEmpty)
        #expect(!CredentialHistory.merged(history, with: [], now: now.addingTimeInterval(-2)).isEmpty)
    }

    @Test("Seeing a value again keeps it, and the list stays bounded") func refreshAndBound() {
        let secret = values(url: "https://site.example.test", secret: "synthetic secret")
        let first = CredentialHistory.merged([], with: secret, now: now.addingTimeInterval(-7 * day))
        let seenAgain = CredentialHistory.merged(first, with: secret, now: now)
        #expect(seenAgain.allSatisfy { $0.lastSeen == now })
        // unchanged within the refresh interval, so nothing is rewritten
        #expect(CredentialHistory.merged(seenAgain, with: secret, now: now.addingTimeInterval(60)) == seenAgain)

        let kinds: [Redactor.Kind] = [.secret, .account, .email, .apiSecret, .nightscoutURL, .remoteSecret, .pushToken]
        let many = kinds.flatMap { kind in
            (0 ..< CredentialHistory.maxEntriesPerKind).map {
                Redactor.ExactValue(value: "synthetic-\(kind.rawValue)-\($0)", kind: kind)
            }
        }
        #expect(many.count > CredentialHistory.maxEntries)
        #expect(CredentialHistory.merged([], with: many, now: now).count == CredentialHistory.maxEntries)
    }

    @Test("History round-trips through the Keychain") func keychainRoundTrip() {
        let keychain = BaseKeychain(serviceName: "CredentialHistoryTests-\(UUID().uuidString)")
        defer { _ = keychain.removeAllKeys() }
        let secret = values(url: "https://site.example.test", secret: "synthetic secret")
        CredentialHistory.record(secret, keychain: keychain, now: now)
        #expect(Set(CredentialHistory.recentValues(keychain: keychain, now: now).map(\.value)) == Set(secret.map(\.value)))
        #expect(CredentialHistory.recentValues(keychain: keychain, now: now.addingTimeInterval(CredentialHistory.keepFor + 1)).isEmpty)
    }

    @Test("Credentials in requests are redacted even when not known") func patterns() {
        let redactor = Redactor(exactValues: [])
        let unknownHash = String(repeating: "ab12", count: 10)
        let cases = [
            ("api-secret: \(unknownHash)", "api-secret: <api-secret>"),
            ("GET /api/v1/entries?token=synthetic-token-1234&count=10", "GET /api/v1/entries?token=<secret-1>&count=10"),
            ("body grant_type=x&refresh_token=synthetic.refresh.token", "body grant_type=x&refresh_token=<secret-1>"),
            ("Authorization: Bearer synthetic.access.token", "Authorization: Bearer <secret-1>")
        ]
        for (input, expected) in cases {
            #expect(Redactor(exactValues: []).redact(input) == expected)
        }
        // ordinary text is left alone
        #expect(redactor.redact("api-secret header missing; tokens=3") == "api-secret header missing; tokens=3")
    }

    @Test("Churning tokens can't evict a replaced password") func perKindCap() {
        let nightscout = values(url: "https://old-site.example.test", secret: "old synthetic secret")
        let password = Redactor.ExactValue(value: "old synthetic password", kind: .secret)
        var history = CredentialHistory.merged([], with: nightscout + [password], now: now.addingTimeInterval(-6 * day))
        // a day's worth of rotating tokens, newer than the old password and secret
        for index in 0 ..< CredentialHistory.maxEntries {
            history = CredentialHistory.merged(
                history,
                with: [Redactor.ExactValue(value: "synthetic-rotating-token-\(index)", kind: .token)],
                now: now.addingTimeInterval(TimeInterval(index))
            )
        }
        #expect(history.filter { $0.kind == Redactor.Kind.token.rawValue }.count == CredentialHistory.maxEntriesPerKind)
        #expect(history.contains { $0.value == "old synthetic secret" })
        #expect(history.contains { $0.value == "old synthetic password" })
    }

    @Test("Session tokens are recorded as tokens, passwords as secrets") func tokenKinds() {
        var values = SensitiveValues()
        values.add(
            rawState: ["accessToken": "synthetic-access-token", "refreshToken": "synthetic-refresh-token", "pinCode": "123456"],
            pluginIdentifier: "AccuChek"
        )
        let kinds = Dictionary(values.values.map { ($0.value, $0.kind) }, uniquingKeysWith: { first, _ in first })
        #expect(kinds["synthetic-access-token"] == .token)
        #expect(kinds["synthetic-refresh-token"] == .token)
        #expect(kinds["123456"] == .secret)
    }

    @Test("A history that can't be decoded is replaced by a fresh one") func undecodableHistoryIsReset() throws {
        let keychain = BaseKeychain(serviceName: "CredentialHistoryTests-\(UUID().uuidString)")
        defer { _ = keychain.removeAllKeys() }
        let garbage = Data("not json".utf8)
        try (keychain.setData(garbage, forKey: CredentialHistory.keychainKey) as Result<Void, KeychainError>).get()

        #expect(CredentialHistory.load(keychain: keychain) == nil)
        CredentialHistory.record(values(url: "https://site.example.test", secret: "synthetic secret"), keychain: keychain, now: now)
        let reloaded = try #require(CredentialHistory.load(keychain: keychain))
        #expect(reloaded.contains { $0.value == "synthetic secret" })

        // and later updates work again
        CredentialHistory.record(
            values(url: "https://other.example.test", secret: "another synthetic secret"),
            keychain: keychain,
            now: now.addingTimeInterval(day)
        )
        #expect(CredentialHistory.load(keychain: keychain)?.contains { $0.value == "another synthetic secret" } == true)
    }
}
