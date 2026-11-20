import Combine
import Foundation
import LoopKit
import Swinject

/// Escalating watchdog for a stalled loop. On every successful loop the
/// pending alarms are retracted and a fresh ladder is armed: a Time-Sensitive
/// warning at 20, 40, 60, 80 and 100 minutes, then a Critical alarm at 120.
///
/// The whole ladder is armed up front rather than re-armed as each one fires.
/// `Alert.Trigger.delayed(interval:)` becomes a `UNTimeIntervalNotification-
/// Trigger`, so the OS owns every step and the Critical alarm still arrives
/// when iOS has suspended Trio — which is the overnight device-failure case
/// the Critical tier exists for. Re-arming as a chain, or counting loop
/// invocations, would both stop dead the moment the app stops running.
///
/// A loop that recovers at any point retracts the remaining steps, so a brief
/// connectivity drop never reaches Critical.
///
/// Replaces the legacy `scheduleMissingLoopNotifiactions` direct-UN path
/// in `BaseUserNotificationsManager`. The alert now flows through
/// `TrioAlertManager` and inherits tier config from Device Alarms
/// (Critical tier by default).
final class NotLoopingMonitor: Injectable {
    @Injected() private var apsManager: APSManager!
    @Injected() private var trioAlertManager: TrioAlertManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var deviceDataManager: DeviceDataManager!

    private var lastLoopDate = Date()

    /// Pump states as last reported by the pump manager. Kept here rather than
    /// read back from `APSManager`, which applies them asynchronously on main
    /// and could still report the old state when a transition arrives.
    /// `nil` until the first report; then `APSManager`'s copy is used.
    private var pumpSuspended: Bool?
    private var manualTempBasalActive: Bool?
    private var automationEnabled: Bool?

    /// Set when looping becomes expected again (pump resumed, manual temp
    /// basal ended, closed loop re-enabled). Loops keep "succeeding" while the
    /// pump is suspended without arming anything, so without this the ladder
    /// would stay disarmed after resume until the next successful loop — and
    /// if looping then failed, no alarm would ever fire.
    private var resumedAt: Date?

    /// Minutes of staleness for each Time-Sensitive warning step.
    private static let warningMinutes: [Int] = [20, 40, 60, 80, 100]

    /// Minutes of staleness before the alarm escalates to Critical. Two hours
    /// of no automated dosing, which is the window discussed for onset of harm
    /// from undelivered insulin.
    private static let criticalMinutes: Int = 120

    /// Critical escalation. Keeps the bare identifier so existing Critical
    /// tier configuration carries over.
    private static let alertID = Alert.Identifier(
        managerIdentifier: "trio.aps",
        alertIdentifier: "loop.notActive"
    )

    /// One identifier per warning step — a single identifier cannot hold more
    /// than one pending notification, the later `add` would replace the earlier.
    private static func warningID(_ step: Int) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "trio.aps", alertIdentifier: "loop.notActive.w\(step)")
    }

    private static var allIDs: [Alert.Identifier] {
        [alertID] + warningMinutes.indices.map { warningID($0 + 1) }
    }

    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        automationEnabled = settingsManager.settings.dosingMode.automation != AutomationLevel.off
        subscribe(to: apsManager.lastLoopDateSubject.eraseToAnyPublisher())
        subscribe(
            suspension: deviceDataManager.suspended.receive(on: DispatchQueue.main).eraseToAnyPublisher(),
            manualTempBasal: deviceDataManager.manualTempBasal.receive(on: DispatchQueue.main).eraseToAnyPublisher()
        )
        broadcaster.register(SnoozeObserver.self, observer: self)
        broadcaster.register(SettingsObserver.self, observer: self)
    }

    /// Publisher-only seam for tests: assigns the alert manager directly and
    /// subscribes to a supplied loop-date publisher, avoiding the need to stub
    /// the full `APSManager` protocol.
    init(
        loopDates: AnyPublisher<Date, Never>,
        trioAlertManager: TrioAlertManager,
        suspension: AnyPublisher<Bool, Never> = Empty().eraseToAnyPublisher(),
        manualTempBasal: AnyPublisher<Bool, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.trioAlertManager = trioAlertManager
        subscribe(to: loopDates)
        subscribe(suspension: suspension, manualTempBasal: manualTempBasal)
    }

    private func subscribe(suspension: AnyPublisher<Bool, Never>, manualTempBasal: AnyPublisher<Bool, Never>) {
        // The pump manager re-sends both flags on every status update, so
        // only real transitions are acted on.
        suspension
            .removeDuplicates()
            .sink { [weak self] suspended in
                guard let self else { return }
                let wasSuspended = self.pumpSuspended
                self.pumpSuspended = suspended
                if wasSuspended == true, !suspended { self.loopingBecameExpected() }
            }
            .store(in: &subscriptions)

        manualTempBasal
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                let wasActive = self.manualTempBasalActive
                self.manualTempBasalActive = active
                if wasActive == true, !active { self.loopingBecameExpected() }
            }
            .store(in: &subscriptions)
    }

    /// Re-arms the ladder when Trio is expected to loop again. The ladder is
    /// anchored to the later of the last successful loop and the moment
    /// looping became expected: a loop history that went stale during a
    /// deliberate suspension must not make every step look already overdue
    /// (overdue steps are skipped, so nothing would fire at all).
    private func loopingBecameExpected() {
        resumedAt = Date()
        rescheduleAlarm()
    }

    private func subscribe(to loopDates: AnyPublisher<Date, Never>) {
        loopDates
            .sink { [weak self] date in
                self?.lastLoopDate = date
                self?.rescheduleAlarm()
            }
            .store(in: &subscriptions)
    }

    private func rescheduleAlarm() {
        // Retract first — clears pending UN, modal timer, and throttler so the
        // next issueAlert isn't blocked by 5-min duplicate suppression.
        for identifier in Self.allIDs {
            trioAlertManager.retractAlert(identifier: identifier)
        }

        // Skip when Trio isn't expected to be auto-enacting: open loop, an
        // active manual temp basal, or a suspended pump. In all three the
        // user has implicitly told Trio "don't loop right now"; a "Not
        // Looping" alarm would just be noise. nil injection (publisher-only
        // test seam) passes so the existing tests still exercise the
        // retract/reschedule plumbing.
        guard automationEnabled ?? (settingsManager?.settings.dosingMode.automation != AutomationLevel.off),
              (manualTempBasalActive ?? apsManager?.isManualTempBasal) != true,
              (pumpSuspended ?? apsManager?.isSuspended) != true
        else { return }

        let now = Date()
        for (index, minutes) in Self.warningMinutes.enumerated() {
            issue(identifier: Self.warningID(index + 1), after: minutes, level: .timeSensitive, now: now)
        }
        issue(identifier: Self.alertID, after: Self.criticalMinutes, level: .critical, now: now)
    }

    /// The catalog decides the interruption level for `trio.aps` alerts, so the
    /// level passed here only matters if the entry is ever removed.
    ///
    /// Steps are measured from the last successful loop, not from `now`, so a
    /// mid-window re-arm keeps the original schedule. A step whose moment has
    /// already passed is skipped rather than fired late.
    private func issue(identifier: Alert.Identifier, after minutes: Int, level: Alert.InterruptionLevel, now: Date) {
        let anchor = max(lastLoopDate, resumedAt ?? .distantPast)
        let fireDate = anchor.addingTimeInterval(TimeInterval(minutes * 60))
        let remaining = fireDate.timeIntervalSince(now)
        guard remaining > 0 else { return }
        let content = Alert.Content(
            title: String(localized: "Trio Not Active"),
            body: String(
                format: String(localized: "Last loop was more than %d min ago"),
                minutes
            ),
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        let alert = Alert(
            identifier: identifier,
            foregroundContent: content,
            backgroundContent: content,
            trigger: .delayed(interval: remaining),
            interruptionLevel: level,
            sound: .sound(name: "honk.caf")
        )
        trioAlertManager.issueAlert(alert)
    }
}

extension NotLoopingMonitor: SnoozeObserver {
    /// A snooze clears pending non-critical notifications wholesale, which
    /// would drop ladder steps scheduled past the end of the window as well as
    /// the ones inside it. Re-arm from the same anchor; `TrioAlertManager`
    /// drops the steps that fall inside the window and keeps the rest.
    @MainActor func snoozeDidChange(_: Date) {
        rescheduleAlarm()
    }
}

extension NotLoopingMonitor: SettingsObserver {
    /// Switching back to closed loop re-arms the ladder the same way a pump
    /// resume does, instead of waiting for the next successful loop.
    func settingsDidChange(_ settings: TrioSettings) {
        let enabled = settings.dosingMode.automation != AutomationLevel.off
        let wasEnabled = automationEnabled
        automationEnabled = enabled
        if wasEnabled == false, enabled { loopingBecameExpected() }
    }
}
