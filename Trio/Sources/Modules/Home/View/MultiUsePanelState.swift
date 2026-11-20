import Foundation

/// Content states of the Home multi-use panel; highest priority wins.
enum MultiUsePanelState: Equatable {
    case notificationsDisabled
    case pumpTimeMismatch
    case cgmStale
    case maxIOBZero
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
        // Uploads only, so it yields to every dosing-related warning above.
        if tidepoolLoginRequired { return .tidepoolLoginRequired }
        // A question, not a warning: yields to everything above, and nothing is sent while it waits.
        if telemetryConsentUndecided { return .telemetryConsent }
        // Informational, so it yields to every warning above but still displaces the stats.
        if hasUnacknowledgedReleaseNotes { return .whatsNew }
        return .stats
    }
}
