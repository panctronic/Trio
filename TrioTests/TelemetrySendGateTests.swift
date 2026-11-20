import Foundation
import Testing

@testable import Trio

@Suite("Telemetry Send Gate Tests") struct TelemetrySendGateTests {
    private let interval: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 2_000_000)

    @Test("Background wake sends when more than 24 hours overdue") func overdueBackgroundWakeSends() async {
        let gate = TelemetrySendGate()
        let sent = await gate.runIfEligible(
            now: now,
            lastSentAt: now.addingTimeInterval(-interval - 1),
            lastAttemptAt: nil,
            minimumInterval: interval,
            retryInterval: 60 * 60
        ) { true }

        #expect(sent)
    }

    @Test("Background wake does nothing before 24 hours") func recentBackgroundWakeDoesNotSend() async {
        let gate = TelemetrySendGate()
        let sent = await gate.runIfEligible(
            now: now,
            lastSentAt: now.addingTimeInterval(-interval + 1),
            lastAttemptAt: nil,
            minimumInterval: interval,
            retryInterval: 60 * 60
        ) { true }

        #expect(!sent)
    }

    @Test("Failed attempt backs off for one hour") func recentFailureBacksOff() async {
        let gate = TelemetrySendGate()
        let sent = await gate.runIfEligible(
            now: now,
            lastSentAt: nil,
            lastAttemptAt: now.addingTimeInterval(-(60 * 60) + 1),
            minimumInterval: interval,
            retryInterval: 60 * 60
        ) { true }

        #expect(!sent)
    }

    @Test("Forced sends still honor failure backoff") func forcedSendHonorsBackoff() async {
        let gate = TelemetrySendGate()
        let sent = await gate.runIfEligible(
            now: now,
            lastSentAt: now,
            lastAttemptAt: now,
            minimumInterval: interval,
            retryInterval: 60 * 60,
            force: true
        ) { true }

        #expect(!sent)
    }

    @Test("Concurrent triggers produce one send") func concurrentTriggersProduceOneSend() async {
        let gate = TelemetrySendGate()
        let attempts = AttemptCounter()
        let testNow = now
        let testInterval = interval

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await gate.runIfEligible(
                        now: testNow,
                        lastSentAt: nil,
                        lastAttemptAt: nil,
                        minimumInterval: testInterval,
                        retryInterval: 60 * 60
                    ) {
                        await attempts.increment()
                        try? await Task.sleep(for: .milliseconds(50))
                        return true
                    }
                }
            }

            var results: [Bool] = []
            for await result in group { results.append(result) }
            #expect(results.filter { $0 }.count == 1)
        }

        #expect(await attempts.value == 1)
    }

    @Test("Failed sends do not advance last-sent state") func failedSendDoesNotAdvanceTimestamp() async {
        let gate = TelemetrySendGate()
        let state = SuccessState()

        let sent = await gate.runIfEligible(
            now: now,
            lastSentAt: nil,
            lastAttemptAt: nil,
            minimumInterval: interval,
            retryInterval: 60 * 60
        ) {
            false
        } onSuccess: {
            state.record()
        }

        #expect(!sent)
        #expect(state.timestamp == nil)
    }

    @Test("Successful sends advance last-sent state") func successfulSendAdvancesTimestamp() async {
        let gate = TelemetrySendGate()
        let state = SuccessState()

        let sent = await gate.runIfEligible(
            now: now,
            lastSentAt: nil,
            lastAttemptAt: nil,
            minimumInterval: interval,
            retryInterval: 60 * 60
        ) {
            true
        } onSuccess: {
            state.record()
        }

        #expect(sent)
        #expect(state.timestamp != nil)
    }

    @Test("Check-in URL includes its trigger reason") func checkinURLIncludesReason() throws {
        let url = try #require(
            TelemetryClient.checkinURL(
                baseURL: URL(string: "https://telemetry.example/api")!,
                reason: .backgroundActivity,
                lastFailureReason: nil
            )
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.path == "/api/checkin")
        #expect(components.queryItems == [URLQueryItem(name: "reason", value: "background_activity")])
    }

    @Test("Check-in URL reports the prior failure") func checkinURLIncludesPriorFailure() throws {
        let url = try #require(
            TelemetryClient.checkinURL(
                baseURL: URL(string: "https://telemetry.example")!,
                reason: .foreground,
                lastFailureReason: "request_failed"
            )
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.contains(URLQueryItem(name: "reason", value: "foreground")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "lastFailureReason", value: "request_failed")) == true)
    }

    @Test("Application ID derives from build team and bundle IDs") func derivesApplicationID() {
        #expect(
            AppAttestClient.appID(teamID: " ABC123 ", bundleID: "org.nightscout.user.trio") ==
                "ABC123.org.nightscout.user.trio"
        )
        #expect(
            AppAttestClient.appID(teamID: "ABC123", bundleID: "com.example.custom-fork") ==
                "ABC123.com.example.custom-fork"
        )
        #expect(AppAttestClient.appID(teamID: "$(DEVELOPMENT_TEAM)", bundleID: "org.example.trio") == nil)
        #expect(AppAttestClient.appID(teamID: "ABC123", bundleID: "com..example") == nil)
    }

    @Test("Provisioning profile returns the first valid application ID") func parsesProvisioningApplicationID() throws {
        let profile: [String: Any] = [
            "Entitlements": [
                "application-identifier": "invalid",
                "com.apple.application-identifier": "ABC123.org.nightscout.user.trio"
            ]
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        var cmsEnvelope = Data([0x00, 0xFF, 0x80, 0x01])
        cmsEnvelope.append(plist)
        cmsEnvelope.append(Data([0xFE, 0x00]))

        #expect(
            AppAttestClient.appID(
                fromProvisioningProfile: cmsEnvelope,
                bundleID: "org.nightscout.fallback.trio"
            ) == "ABC123.org.nightscout.user.trio"
        )
    }

    @Test("Provisioning profile derives app ID from signed team ID") func derivesProvisioningApplicationID() throws {
        let profile: [String: Any] = [
            "Entitlements": ["com.apple.developer.team-identifier": "TEAM123"],
            "TeamIdentifier": ["OTHERTEAM"]
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)

        #expect(
            AppAttestClient.appID(
                fromProvisioningProfile: plist,
                bundleID: "org.nightscout.owner.trio"
            ) == "TEAM123.org.nightscout.owner.trio"
        )
    }

    @Test("Malformed provisioning profiles safely return nil") func malformedProvisioningProfileReturnsNil() {
        let malformedInputs = [Data(), Data([0x00, 0xFF, 0x01]), Data("<?xml broken </plist>".utf8)]

        for data in malformedInputs {
            #expect(
                AppAttestClient.appID(
                    fromProvisioningProfile: data,
                    bundleID: "org.nightscout.owner.trio"
                ) == nil
            )
        }
    }

    @Test("Attestation endpoints include reason and prior failure") func attestationURLsIncludeTelemetryContext() throws {
        for path in ["api/auth/ios/challenge", "api/attest/register"] {
            let url = try #require(
                TelemetryAttestor.requestURL(
                    baseURL: URL(string: "https://telemetry.example")!,
                    path: path,
                    reason: "background_activity",
                    lastFailureReason: "registration_failed"
                )
            )
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

            #expect(components.path == "/\(path)")
            #expect(components.queryItems?.contains(URLQueryItem(name: "reason", value: "background_activity")) == true)
            #expect(
                components.queryItems?.contains(URLQueryItem(name: "lastFailureReason", value: "registration_failed")) == true
            )
        }
    }

    @Test("Telemetry context adds version and install headers") func telemetryContextHeaders() throws {
        let context = TelemetryRequestContext(
            reason: "background_activity",
            lastFailureReason: "registration_failed",
            trioVersion: "0.8.1",
            installID: "install-123"
        )
        var request = URLRequest(url: URL(string: "https://telemetry.example/checkin")!)

        context.applyHeaders(to: &request)

        #expect(request.value(forHTTPHeaderField: "X-Trio-Version") == "0.8.1")
        #expect(request.value(forHTTPHeaderField: "X-Trio-InstallId") == "install-123")
    }

    @Test("Only an explicit opt-in allows telemetry requests") func consentGate() {
        #expect(TelemetryConsent(flag: true).allowsSending)
        #expect(!TelemetryConsent(flag: false).allowsSending)
        // not having chosen is not consent
        #expect(!TelemetryConsent(flag: nil).allowsSending)
        #expect(TelemetryConsent(flag: nil) == .undecided)
    }

    @Test("Only undecided users who finished onboarding are asked") func consentPrompt() {
        #expect(TelemetryConsent.undecided.needsPrompt(onboardingCompleted: true))
        // new users answer in onboarding instead
        #expect(!TelemetryConsent.undecided.needsPrompt(onboardingCompleted: false))
        // an explicit choice either way is kept
        #expect(!TelemetryConsent.optedIn.needsPrompt(onboardingCompleted: true))
        #expect(!TelemetryConsent.optedOut.needsPrompt(onboardingCompleted: true))
    }

    @Test("Opting out deletes the install ID") func optOutDeletesInstallID() {
        let flags = PropertyPersistentFlags.shared
        let previousConsent = flags.telemetrySharingEnabled
        let previousID = flags.telemetryInstallId
        defer {
            flags.telemetrySharingEnabled = previousConsent
            flags.telemetryInstallId = previousID
        }
        flags.telemetryInstallId = "install-to-forget"
        let keychain = TrioApp.resolver.resolve(Keychain.self)!
        let keyIDKey = AppAttestClient.keyIDKey("TelemetryAttest")
        let registeredKey = AppAttestClient.registeredKey("TelemetryAttest")
        let previousKeyID = keychain.getValue(String.self, forKey: keyIDKey) as String?
        let previousRegistered = keychain.getValue(Bool.self, forKey: registeredKey) as Bool?
        defer {
            keychain.setValue(previousKeyID, forKey: keyIDKey)
            keychain.setValue(previousRegistered, forKey: registeredKey)
        }
        keychain.setValue("key-to-forget", forKey: keyIDKey)
        keychain.setValue(true, forKey: registeredKey)

        TelemetryClient.recordConsent(false)
        #expect(flags.telemetrySharingEnabled == false)
        #expect(flags.telemetryInstallId == nil)
        // a later opt-in registers a new App Attest key
        #expect((keychain.getValue(String.self, forKey: keyIDKey) as String?) == nil)
        #expect((keychain.getValue(Bool.self, forKey: registeredKey) as Bool?) == nil)
    }

    @Test("The payload carries no identifier that outlives an opt-out") func payloadHasNoVendorID() {
        #expect(TelemetryClient.shared.buildPayload()["idfv"] == nil)
    }

    @Test("\"Not Now\" puts the prompt away for a week") func consentPromptSnooze() {
        let snoozedUntil = now.addingTimeInterval(TelemetryConsent.promptSnooze)
        #expect(!TelemetryConsent.undecided.needsPrompt(onboardingCompleted: true, snoozedUntil: snoozedUntil, now: now))
        #expect(!TelemetryConsent.undecided.needsPrompt(
            onboardingCompleted: true,
            snoozedUntil: snoozedUntil,
            now: snoozedUntil.addingTimeInterval(-1)
        ))
        #expect(TelemetryConsent.undecided.needsPrompt(onboardingCompleted: true, snoozedUntil: snoozedUntil, now: snoozedUntil))
        #expect(TelemetryConsent.promptSnooze == 7 * 24 * 60 * 60)
    }

    @Test("Usage data settings show telemetry as off until the user opts in") func diagnosticsOptionReflectsConsent() {
        #expect(DiagnosticsSharingOption(crashlyticsEnabled: true, telemetryEnabled: TelemetryConsent(flag: nil).allowsSending) ==
            .crashOnly)
        #expect(DiagnosticsSharingOption(crashlyticsEnabled: true, telemetryEnabled: TelemetryConsent(flag: true).allowsSending) ==
            .full)
        #expect(!DiagnosticsSharingOption.crashOnly.telemetryEnabled)
        #expect(!DiagnosticsSharingOption.disabled.telemetryEnabled)
    }
}

private actor AttemptCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class SuccessState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTimestamp: Date?

    var timestamp: Date? {
        lock.withLock { storedTimestamp }
    }

    func record() {
        lock.withLock { storedTimestamp = Date() }
    }
}
