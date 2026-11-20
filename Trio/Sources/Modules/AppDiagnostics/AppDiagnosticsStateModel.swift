import Observation
import SwiftUI

extension AppDiagnostics {
    @Observable final class StateModel: BaseStateModel<Provider> {
        // MARK: - Diagnostics Sharing Option

        var diagnosticsSharingOption: DiagnosticsSharingOption = .full

        override func subscribe() {
            loadDiagnostics()
        }

        /// Derives the 3-state option from the two underlying flags. Crash
        /// reporting is on unless switched off (`nil` ⇒ on); usage telemetry is
        /// opt-in, so it only counts as on after an explicit yes (`nil` ⇒ off).
        func loadDiagnostics() {
            let crashlytics = PropertyPersistentFlags.shared.crashlyticsSharingEnabled ?? true
            let telemetry = TelemetryConsent.current.allowsSending
            diagnosticsSharingOption = DiagnosticsSharingOption(
                crashlyticsEnabled: crashlytics,
                telemetryEnabled: telemetry
            )
        }

        /// Called when the user picks an option: persists it to both underlying
        /// flags and applies it to Crashlytics and the telemetry sender. Only a
        /// tap calls this, so merely opening the screen never records a choice.
        func select(_ option: DiagnosticsSharingOption) {
            diagnosticsSharingOption = option
            PropertyPersistentFlags.shared.crashlyticsSharingEnabled = option.crashlyticsEnabled

            // Opting out also drops whatever GoogleDataTransport already queued,
            // so no crash-reporting upload survives the switch.
            CrashReportingGate.setEnabled(option.crashlyticsEnabled)

            // Stores the explicit choice; a fresh opt-in sends right away rather than 24h later.
            TelemetryClient.recordConsent(option.telemetryEnabled)
        }
    }
}

extension AppDiagnostics.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {}
}

/// Three-state diagnostics-sharing selection.
///
/// Maps to a pair of independent `Bool?` flags in `PropertyPersistentFlags`:
/// `crashlyticsSharingEnabled` (Crashlytics) and `telemetrySharingEnabled`
/// (the opt-in usage check-in). See `TelemetryClient`.
enum DiagnosticsSharingOption: String, Equatable, CaseIterable, Identifiable {
    case full
    case crashOnly
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full:
            return String(localized: "Enable Full Sharing")
        case .crashOnly:
            return String(localized: "Crash Reports Only")
        case .disabled:
            return String(localized: "Disable Sharing")
        }
    }

    var caption: String {
        switch self {
        case .full:
            return String(localized: "Share anonymous crash reports + usage data.")
        case .crashOnly:
            return String(localized: "Share only crash reports — no usage data.")
        case .disabled:
            return String(localized: "Do not share any diagnostic data.")
        }
    }

    var crashlyticsEnabled: Bool {
        switch self {
        case .crashOnly,
             .full: return true
        case .disabled: return false
        }
    }

    var telemetryEnabled: Bool {
        switch self {
        case .full: return true
        case .crashOnly,
             .disabled: return false
        }
    }

    init(crashlyticsEnabled: Bool, telemetryEnabled: Bool) {
        switch (crashlyticsEnabled, telemetryEnabled) {
        case (true, true): self = .full
        case (true, false): self = .crashOnly
        case (false, true): self = .full // unreachable in normal flow
        case (false, false): self = .disabled
        }
    }
}
