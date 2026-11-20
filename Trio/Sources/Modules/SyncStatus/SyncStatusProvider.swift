import Foundation
import HealthKit

extension SyncStatus {
    final class Provider: BaseProvider, SyncStatusProvider {
        @Injected() private var keychain: Keychain!
        @Injected() private var settingsManager: SettingsManager!
        @Injected() private var tidepoolManager: TidepoolManager!
        @Injected() private var healthKitManager: HealthKitManager!

        func availability(of destination: SyncDestination) -> SyncAvailability {
            let settings = settingsManager.settings
            switch destination {
            case .nightscout:
                guard settings.isUploadEnabled else { return .off }
                let missing = MultiUsePanelState.nightscoutCredentialsMissing(
                    uploadEnabled: true,
                    url: keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey),
                    secret: keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey)
                )
                // nil: the Keychain could not be read (phone locked); don't claim credentials are missing.
                if missing == true {
                    return .blocked(String(localized: "Uploads are on, but the Nightscout URL or API secret is missing."))
                }
                return .on

            case .tidepool:
                guard tidepoolManager.getTidepoolServiceUI() != nil else { return .off }
                if tidepoolManager.tidepoolLoginRequired.value {
                    return .blocked(String(localized: "Tidepool needs you to log in again."))
                }
                return .on

            case .appleHealth:
                guard HKHealthStore.isHealthDataAvailable(), settings.useAppleHealth else { return .off }
                guard healthKitManager.hasGlucoseWritePermission() else {
                    return .blocked(
                        String(
                            localized: "Trio is not allowed to write to Apple Health. Check the permissions in the Health app."
                        )
                    )
                }
                return .on
            }
        }

        func backlog(for destination: SyncDestination) async -> SyncBacklog? {
            await SyncBacklogCounter(fileStorage: storage).backlog(
                for: destination,
                includeNightscoutGlucose: settingsManager.settings.uploadGlucose
            )
        }

        /// Asks the destination's existing upload passes to run now. No upload logic of its own.
        func requestUpload(to destination: SyncDestination) {
            switch destination {
            case .nightscout:
                requestNightscoutUpload(
                    [.glucose, .pumpHistory, .carbs, .overrides, .tempTargets, .deviceStatus],
                    source: "SyncStatus"
                )
            case .tidepool:
                tidepoolManager.forceTidepoolDataUpload()
            case .appleHealth:
                let healthKitManager = healthKitManager
                Task(priority: .utility) {
                    await healthKitManager?.uploadGlucose()
                    await healthKitManager?.uploadCarbs()
                    await healthKitManager?.uploadInsulin()
                }
            }
        }
    }
}
