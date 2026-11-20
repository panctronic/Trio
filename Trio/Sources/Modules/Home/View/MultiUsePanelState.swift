import Foundation

/// Content states of the Home multi-use panel; highest priority wins.
enum MultiUsePanelState: Equatable {
    case notificationsDisabled
    case pumpTimeMismatch
    case cgmStale
    case maxIOBZero
    /// Nightscout upload is on, but its URL or API secret reads back empty: uploads stop without this.
    case nightscoutCredentialsMissing
    case tidepoolLoginRequired
    /// Set up before usage data sharing became opt-in and never asked; nothing is sent until answered.
    case telemetryConsent
    case whatsNew
    case dosingModeLimited(DosingMode)
    case stats

    /// readings older than this offer manual glucose entry
    static let cgmStaleAfter: TimeInterval = 12 * 60

    static func resolve(
        notificationsDisabled: Bool,
        pumpTimeMismatch: Bool,
        lastGlucoseDate: Date?,
        maxIOB: Decimal,
        tidepoolLoginRequired: Bool,
        hasUnacknowledgedReleaseNotes: Bool,
        telemetryConsentUndecided: Bool = false,
        nightscoutCredentialsMissing: Bool = false,
        dosingMode: DosingMode,
        now: Date
    ) -> MultiUsePanelState {
        if notificationsDisabled { return .notificationsDisabled }
        if pumpTimeMismatch { return .pumpTimeMismatch }
        if now.timeIntervalSince(lastGlucoseDate ?? .distantPast) > cgmStaleAfter { return .cgmStale }
        // constrained modes clamp Max IOB to 0 without touching the stored value
        if dosingMode.automation == .reductionsOnly || dosingMode.automation == .hypoSuspendOnly {
            return .dosingModeLimited(dosingMode)
        }
        if maxIOB <= 0 { return .maxIOBZero }
        // Uploads only, so these yield to every dosing-related warning above.
        if nightscoutCredentialsMissing { return .nightscoutCredentialsMissing }
        if tidepoolLoginRequired { return .tidepoolLoginRequired }
        // A question, not a warning: yields to everything above, and nothing is sent while it waits.
        if telemetryConsentUndecided { return .telemetryConsent }
        // Informational, so it yields to every warning above but still displaces the stats.
        if hasUnacknowledgedReleaseNotes { return .whatsNew }
        return .stats
    }
}

extension MultiUsePanelState {
    /// Whether to warn that Nightscout upload is on without credentials: true when the URL or secret definitely reads
    /// back empty, false when both are there or upload is off, nil when the Keychain couldn't be read (keep whatever
    /// was shown before rather than flash a warning while the phone is locked).
    static func nightscoutCredentialsMissing(
        uploadEnabled: Bool,
        url: Result<String?, KeychainError>,
        secret: Result<String?, KeychainError>
    ) -> Bool? {
        guard uploadEnabled else { return false }
        guard case let .success(urlValue) = url, case let .success(secretValue) = secret else { return nil }
        let isEmpty = { (value: String?) in (value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
        return isEmpty(urlValue) || isEmpty(secretValue)
    }
}
