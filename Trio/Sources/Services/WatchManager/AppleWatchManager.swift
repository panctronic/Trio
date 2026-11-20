import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import WatchConnectivity

/// Protocol defining the base functionality for Watch communication
protocol WatchManager {
    func setupWatchState() async -> WatchState?
}

/// Main implementation of the Watch communication manager
/// Handles bidirectional communication between iPhone and Apple Watch
final class BaseWatchManager: NSObject, WCSessionDelegate, Injectable, WatchManager {
    private var session: WCSession?

    @Injected() var broadcaster: Broadcaster!
    @Injected() private var apsManager: APSManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var carbsStorage: CarbsStorage!

    /// Outcome (logged or not) of recent Watch carb entries, by their date, for the bolus the Watch sends with them
    @MainActor private var watchCarbsOutcomes: [TimeInterval: Task<Bool, Never>] = [:]
    /// The last Watch carbs received, for a bolus from an older Watch app that does not say which carbs it belongs to
    @MainActor private var lastWatchCarbs: (receivedAt: Date, outcome: Task<Bool, Never>)?
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var tempTargetStorage: TempTargetsStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!
    @Injected() private var bolusCalculationManager: BolusCalculationManager!
    @Injected() private var bolusSafetyValidator: BolusSafetyValidator!
    @Injected() private var iobService: IOBService!
    @Injected() private var notificationsManager: UserNotificationsManager!

    private var units: GlucoseUnits = .mgdL
    private var glucoseColorScheme: GlucoseColorScheme = .staticColor
    private var lowGlucose: Decimal = 70.0
    private var highGlucose: Decimal = 180.0
    private var activeBolusAmount: Double = 0.0

    // Queue for handling Core Data change notifications
    private let queue = DispatchQueue(label: "BaseWatchManagerManager.queue", qos: .utility)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Only accessed on `queue`.
    private var pendingPushSince: Date?
    /// Longest wait for a running loop.
    private static let maxLoopWait: TimeInterval = 30

    typealias PumpEvent = PumpEventStored.EventType

    let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    init(resolver: Resolver) {
        super.init()
        injectServices(resolver)
        setupWatchSession()

        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PumpSettingsObserver.self, observer: self)
        broadcaster.register(SnoozeObserver.self, observer: self)

        // Observer for OrefDetermination and adjustments
        coreDataPublisher =
            CoreDataStack.shared.contentChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        // Observer for glucose and manual glucose
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                self?.scheduleWatchStatePush()
            }
            .store(in: &subscriptions)

        iobService.iobPublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                self?.scheduleWatchStatePush()
            }
            .store(in: &subscriptions)

        registerHandlers()
    }

    /// Bundles triggers that land together.
    private func scheduleWatchStatePush() {
        guard let session = session, session.isPaired, session.isWatchAppInstalled else { return }

        queue.async { [weak self] in
            guard let self, self.pendingPushSince == nil else { return }
            self.pendingPushSince = Date()
            self.pushAfterLoop(delay: 0.5)
        }
    }

    /// Waits for a running loop, capped. Only on `queue`.
    private func pushAfterLoop(delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let since = self.pendingPushSince else { return }
            if self.apsManager.isLooping.value, Date().timeIntervalSince(since) < Self.maxLoopWait {
                self.pushAfterLoop(delay: 1)
                return
            }
            self.pendingPushSince = nil
            Task {
                await self.pushWatchState()
            }
        }
    }

    private func pushWatchState() async {
        guard let state = await setupWatchState() else { return }
        await sendDataToWatch(state)
    }

    private func registerHandlers() {
        coreDataPublisher?.filteredByEntityName("OrefDetermination").sink { [weak self] _ in
            self?.scheduleWatchStatePush()
        }.store(in: &subscriptions)

        // Due to the Batch insert this only is used for observing Deletion of Glucose entries
        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            self?.scheduleWatchStatePush()
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("PumpEventStored").sink { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.getActiveBolusAmount()
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            self?.scheduleWatchStatePush()
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            self?.scheduleWatchStatePush()
        }.store(in: &subscriptions)
    }

    /// Sets up the WatchConnectivity session if the device supports it
    private func setupWatchSession() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session

            debug(.watch, "Watch session set up, paired: \(session.isPaired)")
        } else {
            debug(.watch, "Watch connectivity not supported on this device")
        }
    }

    /// Attempts to reestablish the Watch connection if it becomes unreachable
    private func retryConnection() {
        guard let session = session else { return }

        if !session.isReachable {
            debug(.watch, "Reactivating watch session")
            session.activate()
        }
    }

    /// Prepares the current state data to be sent to the Watch
    /// - Returns: WatchState containing current glucose readings and trends and determination infos for displaying cob and iob in the view
    func setupWatchState() async -> WatchState? {
        // Unreachable watches still get the context.
        guard let session = session, session.isPaired, session.isWatchAppInstalled else {
            debug(.watch, "Watch state skipped: no watch paired or app not installed")
            return nil
        }

        // Skip if watch session is not activated
        guard session.activationState == .activated else {
            debug(.watch, "Watch state skipped: session not activated")
            return nil
        }
        do {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "setupWatchState"

            // Get NSManagedObjectIDs
            let glucoseIds = try await fetchGlucose()
            let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let overridePresetIds = try await overrideStorage.fetchForOverridePresets()
            let tempTargetPresetIds = try await tempTargetStorage.fetchForTempTargetPresets()
            // Per build: the target follows the time.
            let currentGlucoseTarget = await getCurrentGlucoseTarget() ?? Decimal(100)

            // Get NSManagedObjects
            let glucoseObjects: [GlucoseStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: glucoseIds, context: context)
            let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared
                .getNSManagedObject(with: determinationIds, context: context)
            let overridePresetObjects: [OverrideStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: overridePresetIds, context: context)
            let tempTargetPresetObjects: [TempTargetStored] = try await CoreDataStack.shared
                .getNSManagedObject(with: tempTargetPresetIds, context: context)

            let watchState: WatchState = await context.perform {
                var watchState = WatchState(date: Date())
                watchState.snoozeUntilDate = UserDefaults.standard
                    .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date ?? .distantPast

                // Set lastLoopDate
                let lastLoopMinutes = Int((Date().timeIntervalSince(self.apsManager.lastLoopDate) - 30) / 60) + 1
                if lastLoopMinutes > 1440 {
                    watchState.lastLoopTime = "--"
                } else {
                    watchState.lastLoopTime = "\(lastLoopMinutes) min"
                }

                // Set IOB and COB from latest determination
                let iob = self.iobService.currentIOB ?? 0
                watchState.iob = iob.formattedIOB()

                if let latestDetermination = determinationObjects.first {
                    let cob = NSNumber(value: latestDetermination.cob)
                    watchState.cob = Formatter.integerFormatter.string(from: cob)
                }

                // Set override presets with their enabled status
                watchState.overridePresets = overridePresetObjects.map { override in
                    OverridePresetWatch(
                        name: override.name ?? "",
                        isEnabled: override.enabled
                    )
                }

                guard let latestGlucose = glucoseObjects.first else {
                    return watchState
                }

                // Assign currentGlucose and its color
                /// Set current glucose with proper formatting
                watchState.currentGlucose = Decimal(latestGlucose.glucose).formatted(for: self.units)

                /// Calculate latest color
                let hardCodedLow = Decimal(55)
                let hardCodedHigh = Decimal(220)
                let isDynamicColorScheme = self.glucoseColorScheme == .dynamicColor

                let highGlucoseValue = isDynamicColorScheme ? hardCodedHigh : self.highGlucose
                let lowGlucoseValue = isDynamicColorScheme ? hardCodedLow : self.lowGlucose
                let highGlucoseColorValue = highGlucoseValue
                let lowGlucoseColorValue = lowGlucoseValue
                let targetGlucose = currentGlucoseTarget

                let currentGlucoseColor = Trio.getDynamicGlucoseColor(
                    glucoseValue: Decimal(latestGlucose.glucose),
                    highGlucoseColorValue: highGlucoseColorValue,
                    lowGlucoseColorValue: lowGlucoseColorValue,
                    targetGlucose: targetGlucose,
                    glucoseColorScheme: self.glucoseColorScheme
                )

                if Decimal(latestGlucose.glucose) <= self.lowGlucose || Decimal(latestGlucose.glucose) >= self.highGlucose {
                    watchState.currentGlucoseColorString = currentGlucoseColor.toHexString()
                } else {
                    watchState.currentGlucoseColorString = "#ffffff" // white when in range; colored when out of range
                }

                // Map glucose values
                watchState.glucoseValues = glucoseObjects.compactMap { glucose in
                    let glucoseValue = self.units == .mgdL
                        ? Double(glucose.glucose)
                        : Double(truncating: Decimal(glucose.glucose).asMmolL as NSNumber)

                    let glucoseColor = Trio.getDynamicGlucoseColor(
                        glucoseValue: Decimal(glucose.glucose),
                        highGlucoseColorValue: highGlucoseColorValue,
                        lowGlucoseColorValue: lowGlucoseColorValue,
                        targetGlucose: targetGlucose,
                        glucoseColorScheme: self.glucoseColorScheme
                    )

                    return WatchGlucoseObject(
                        date: glucose.date ?? Date(),
                        glucose: glucoseValue,
                        color: glucoseColor.toHexString()
                    )
                }
                .sorted { $0.date < $1.date }

                // Set axis domain: min and max Y-axis values
                // Apply unit parsing conditionally, if user uses mmol/L
                let maxGlucoseValue = Decimal(glucoseObjects.map { Int($0.glucose) }.max() ?? 200)
                var maxYValue = Decimal(200)

                if maxGlucoseValue > maxYValue, maxGlucoseValue <= 225 {
                    maxYValue = Decimal(250)
                } else if maxGlucoseValue > 225, maxGlucoseValue <= 275 {
                    maxYValue = Decimal(300)
                } else if maxGlucoseValue > 275, maxGlucoseValue <= 325 {
                    maxYValue = Decimal(350)
                } else if maxGlucoseValue > 325 {
                    maxYValue = Decimal(400)
                }

                if self.units == .mmolL {
                    maxYValue = Double(truncating: maxYValue as NSNumber).asMmolL
                }
                watchState.maxYAxisValue = maxYValue

                if self.units == .mmolL {
                    let minYValue = Double(truncating: watchState.minYAxisValue as NSNumber).asMmolL
                    watchState.minYAxisValue = minYValue
                }

                // Convert direction to trend string
                watchState.trend = latestGlucose.direction

                // Calculate delta if we have at least 2 readings
                if glucoseObjects.count >= 2 {
                    let glucoseLast = Decimal(glucoseObjects[0].glucose)
                    let glucoseSecondLast = Decimal(glucoseObjects[1].glucose)
                    watchState.delta = (glucoseLast - glucoseSecondLast).formattedDelta(for: self.units)
                }

                // Set temp target presets with their enabled status
                watchState.tempTargetPresets = tempTargetPresetObjects.map { tempTarget in
                    TempTargetPresetWatch(
                        name: tempTarget.name ?? "",
                        isEnabled: tempTarget.enabled
                    )
                }

                // Set units
                watchState.units = self.units

                // Add limits and pump specific dosing increment settings values
                watchState.maxBolus = self.settingsManager.pumpSettings.maxBolus
                watchState.maxCarbs = self.settingsManager.settings.maxCarbs
                watchState.maxFat = self.settingsManager.settings.maxFat
                watchState.maxProtein = self.settingsManager.settings.maxProtein
                watchState.bolusIncrement = self.settingsManager.preferences.bolusIncrement
                watchState.confirmBolusFaster = self.settingsManager.settings.confirmBolusFaster

                watchState.showForecast = self.settingsManager.settings.showForecastWatch
                watchState.isForecastCone = self.settingsManager.settings.forecastDisplayType == .cone

                // Forecast data comes from OrefDetermination's `forecasts` CoreData
                // relationship (Set<Forecast>), NOT a `.predictions` property.
                if let latestDetermination = determinationObjects.first,
                   let forecastsSet = latestDetermination.forecasts,
                   !forecastsSet.isEmpty
                {
                    let anchorDate = latestDetermination.deliverAt ?? latestDetermination.timestamp ?? Date()
                    watchState.forecastStartDate = anchorDate

                    // Rebuild a [type: [Int]] dictionary from the CoreData relationship.
                    // Strictly cap to 24 points (2 hours of 5-minute forecasts)
                    var rawPredictions: [String: [Int]] = [:]
                    for forecast in forecastsSet {
                        guard let type = forecast.type else { continue }
                        let values = Array(forecast.forecastValuesArray.map { Int($0.value) }.prefix(24))
                        guard !values.isEmpty else { continue }
                        rawPredictions[type] = values
                    }

                    func convert(_ values: [Int]?) -> [Double] {
                        guard let values = values else { return [] }
                        return values.map { raw in
                            self.units == .mgdL ? Double(raw) : Double(truncating: Decimal(raw).asMmolL as NSNumber)
                        }
                    }

                    if watchState.isForecastCone {
                        let allSeries: [[Int]] = [
                            rawPredictions["iob"],
                            rawPredictions["zt"],
                            rawPredictions["cob"],
                            rawPredictions["uam"]
                        ].compactMap { $0 }

                        // Change .max() to .min() so the shortest prediction line cuts off the cone
                        let count = allSeries.map(\.count).min() ?? 0

                        var coneMin: [Double] = []
                        var coneMax: [Double] = []
                        for i in 0 ..< count {
                            let valuesAtIndex = allSeries.compactMap { $0.indices.contains(i) ? $0[i] : nil }
                            guard let minRaw = valuesAtIndex.min(), let maxRaw = valuesAtIndex.max() else { continue }
                            coneMin.append(convert([minRaw])[0])
                            coneMax.append(convert([maxRaw])[0])
                        }
                        watchState.forecastConeMin = coneMin
                        watchState.forecastConeMax = coneMax
                        watchState.forecastLines = [:]
                    } else {
                        var lines: [String: [Double]] = [:]
                        if let iob = rawPredictions["iob"] { lines["iob"] = convert(iob) }
                        if let cob = rawPredictions["cob"] { lines["cob"] = convert(cob) }
                        if let uam = rawPredictions["uam"] { lines["uam"] = convert(uam) }
                        if let zt = rawPredictions["zt"] { lines["zt"] = convert(zt) }
                        watchState.forecastLines = lines
                        watchState.forecastConeMin = []
                        watchState.forecastConeMax = []
                    }
                } else {
                    watchState.forecastStartDate = nil
                    watchState.forecastConeMin = []
                    watchState.forecastConeMax = []
                    watchState.forecastLines = [:]
                }

                debug(
                    .watch,
                    "Watch state built: glucose \(watchState.currentGlucose ?? "none"), trend \(watchState.trend ?? "none"), delta \(watchState.delta ?? "none"), \(watchState.glucoseValues.count) readings"
                )

                return watchState
            }

            return watchState
        } catch {
            warning(.watch, "Building watch state failed", error: error)
            return nil
        }
    }

    /// Fetches recent glucose readings from CoreData
    /// - Returns: Array of NSManagedObjectIDs for glucose readings
    private func fetchGlucose() async throws -> [NSManagedObjectID] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchGlucose"
        return try await CoreDataStack.shared.fetchObjectIDs(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.glucose,
            key: "date",
            ascending: false
        )
    }

    /// Fetches last pump event that is a non-external bolus from CoreData
    /// - Returns: NSManagedObjectIDs for last bolus
    func fetchLastBolus() async throws -> NSManagedObjectID? {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "fetchLastBolus"
        return try await CoreDataStack.shared.fetchObjectIDs(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate.lastPumpBolus,
            key: "timestamp",
            ascending: false,
            fetchLimit: 1,
            relationshipKeyPathsForPrefetching: ["bolus"]
        ).first
    }

    /// Gets the active bolus amount by fetching last (active) bolus.
    @MainActor func getActiveBolusAmount() async {
        do {
            if let lastBolusObjectId = try await fetchLastBolus() {
                let lastBolusObject: [PumpEventStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: [lastBolusObjectId], context: viewContext)

                activeBolusAmount = lastBolusObject.first?.bolus?.amount?.doubleValue ?? 0.0
            }
        } catch {
            warning(.watch, "Fetching active bolus amount failed", error: error)
        }
    }

    // MARK: - Send to Watch

    func watchStateToDictionary(from state: WatchState) -> [String: Any] {
        var dictionary: [String: Any] = [
            WatchMessageKeys.date: state.date.timeIntervalSince1970,
            WatchMessageKeys.currentGlucose: state.currentGlucose ?? "--",
            WatchMessageKeys.currentGlucoseColorString: state.currentGlucoseColorString ?? "#ffffff",
            WatchMessageKeys.trend: state.trend ?? "",
            WatchMessageKeys.delta: state.delta ?? "",
            WatchMessageKeys.iob: state.iob ?? "",
            WatchMessageKeys.cob: state.cob ?? "",
            WatchMessageKeys.lastLoopTime: state.lastLoopTime ?? "",
            WatchMessageKeys.glucoseValues: state.glucoseValues.map { value in
                [
                    "glucose": value.glucose,
                    "date": value.date.timeIntervalSince1970,
                    "color": value.color
                ]
            },
            WatchMessageKeys.minYAxisValue: state.minYAxisValue,
            WatchMessageKeys.maxYAxisValue: state.maxYAxisValue,
            WatchMessageKeys.overridePresets: state.overridePresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.tempTargetPresets: state.tempTargetPresets.map { preset in
                [
                    "name": preset.name,
                    "isEnabled": preset.isEnabled
                ]
            },
            WatchMessageKeys.maxBolus: state.maxBolus,
            WatchMessageKeys.maxCarbs: state.maxCarbs,
            WatchMessageKeys.maxFat: state.maxFat,
            WatchMessageKeys.maxProtein: state.maxProtein,
            WatchMessageKeys.bolusIncrement: state.bolusIncrement,
            WatchMessageKeys.confirmBolusFaster: state.confirmBolusFaster,
            WatchMessageKeys.units: state.units.rawValue,
            WatchMessageKeys.showForecastWatch: state.showForecast,
            WatchMessageKeys.isForecastCone: state.isForecastCone,
            WatchMessageKeys.snoozeUntilDate: state.snoozeUntilDate.timeIntervalSince1970
        ]

        var forecastData: [String: Any] = [
            WatchMessageKeys.forecastConeMin: state.forecastConeMin,
            WatchMessageKeys.forecastConeMax: state.forecastConeMax,
            WatchMessageKeys.forecastLines: state.forecastLines
        ]

        if let start = state.forecastStartDate?.timeIntervalSince1970 {
            forecastData[WatchMessageKeys.forecastStartDate] = start
        }

        dictionary[WatchMessageKeys.forecastData] = forecastData
        return dictionary
    }

    // MARK: - Watch state payloads

    /// Sends the state of type WatchState to the connected Watch
    /// - Parameter state: Current WatchState containing glucose data to be sent
    @MainActor func sendDataToWatch(_ state: WatchState) async {
        guard let session = session, let payload = buildWatchStatePayload(state) else { return }
        updateApplicationContext(with: payload)

        // Reachable means foreground: also send a message.
        guard session.isReachable else { return }

        session.sendMessage([WatchMessageKeys.watchState: payload], replyHandler: nil) { error in
            warning(.watch, "Sending watch state failed", error: error)
        }
    }

    /// Payload stamped with the send time.
    @MainActor private func buildWatchStatePayload(_ state: WatchState) -> [String: Any]? {
        guard let session = session else { return nil }

        guard session.isPaired else {
            debug(.watch, "No watch paired")
            return nil
        }

        guard session.isWatchAppInstalled else {
            debug(.watch, "Trio watch app not installed")
            return nil
        }

        guard session.activationState == .activated else {
            debug(.watch, "Watch session not activated (state \(session.activationState.rawValue)), reactivating")
            session.activate()
            return nil
        }

        // Stamp the snapshot with send time. Each push gets a strictly newer
        // `date` than the previous one, which is what the watch's monotonicity
        // dedup relies on — including watch-requested re-pushes when no CGM
        // tick has bumped the build-time date.
        var state = state
        state.date = Date()

        return watchStateToDictionary(from: state)
    }

    @MainActor private func updateApplicationContext(with payload: [String: Any]) {
        do {
            try session?.updateApplicationContext([WatchMessageKeys.watchState: payload])
        } catch {
            warning(.watch, "Updating the watch application context failed", error: error)
        }
    }

    func sendAcknowledgment(
        toWatch success: Bool,
        message: String = "",
        ackCode: AcknowledgmentCode,
        details: [String: Any] = [:]
    ) {
        guard let session = session, session.isReachable else {
            debug(.watch, "Watch not reachable, acknowledgment not sent")
            return
        }

        let ackMessage: [String: Any] = details.merging([
            WatchMessageKeys.acknowledged: success,
            WatchMessageKeys.message: message,
            WatchMessageKeys.ackCode: ackCode.rawValue
        ]) { _, ack in ack }

        session.sendMessage(ackMessage, replyHandler: nil) { error in
            warning(.watch, "Sending acknowledgment to watch failed", error: error)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            warning(.watch, "Watch session activation failed", error: error)
            return
        }

        info(.watch, "Watch session activated, state \(activationState.rawValue), reachable: \(session.isReachable)")

        // Try to send initial data after activation
        Task {
            await self.pushWatchState()
        }
    }

    /// Every path must call `replyHandler`.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let requestWatchUpdate = message[WatchMessageKeys.requestWatchUpdate] as? String,
              requestWatchUpdate == WatchMessageKeys.watchState
        else {
            replyHandler([:])
            self.session(session, didReceiveMessage: message)
            return
        }

        debug(.watch, "Watch requested a state update")

        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler([:])
                return
            }

            guard let state = await self.setupWatchState(),
                  let payload = self.buildWatchStatePayload(state)
            else {
                replyHandler([:])
                return
            }
            // Context as fresh as the reply.
            self.updateApplicationContext(with: payload)
            replyHandler([WatchMessageKeys.watchState: payload])
        }
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        // Handle logs first - doesn't need self, so it can run even during teardown
        if let logs = message["watchLogs"] as? String {
            WatchLogIngest.legacyRecords(from: logs).forEach(TrioLogger.sink.accept)
            if message.count == 1 { return }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Older watch apps ask without reply handler.
            if message[WatchMessageKeys.requestWatchUpdate] as? String == WatchMessageKeys.watchState {
                debug(.watch, "Watch requested a state update without a reply handler")
                await self.pushWatchState()
                return
            }

            if let snoozeMinutes = message[WatchMessageKeys.snoozeDuration] as? Int {
                info(.watch, "Watch requested alert snooze for \(snoozeMinutes) min")
                await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
                return
            } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                      message[WatchMessageKeys.carbs] == nil,
                      message[WatchMessageKeys.date] == nil
            {
                info(.watch, "Watch requested bolus of \(bolusAmount) U")
                self.handleBolusRequest(
                    Decimal(bolusAmount),
                    overriding: self.overriddenBolusChecks(in: message),
                    mealDate: message[WatchMessageKeys.mealDate] as? TimeInterval
                )
            } else if let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                      let timestamp = message[WatchMessageKeys.date] as? TimeInterval,
                      message[WatchMessageKeys.bolus] == nil
            {
                let date = Date(timeIntervalSince1970: timestamp)
                info(.watch, "Watch requested \(carbsAmount) g carbs at \(date)")
                self.handleCarbsRequest(carbsAmount, date)
            } else if let bolusAmount = message[WatchMessageKeys.bolus] as? Double,
                      let carbsAmount = message[WatchMessageKeys.carbs] as? Int,
                      let timestamp = message[WatchMessageKeys.date] as? TimeInterval
            {
                let date = Date(timeIntervalSince1970: timestamp)
                info(.watch, "Watch requested bolus of \(bolusAmount) U with \(carbsAmount) g carbs at \(date)")
                self.handleCombinedRequest(
                    bolusAmount: Decimal(bolusAmount),
                    carbsAmount: Decimal(carbsAmount),
                    date: date,
                    overriding: self.overriddenBolusChecks(in: message)
                )
            } else if message[WatchMessageKeys.cancelOverride] == nil,
                      message[WatchMessageKeys.activateOverride] == nil,
                      message[WatchMessageKeys.cancelTempTarget] == nil,
                      message[WatchMessageKeys.activateTempTarget] == nil,
                      message[WatchMessageKeys.requestBolusRecommendation] == nil
            {
                warning(
                    .watch,
                    "Invalid or incomplete message from watch, keys: \(message.keys.sorted().joined(separator: ", "))"
                )
                // Acknowledge failure
                self.sendAcknowledgment(
                    toWatch: false,
                    message: "Error! Invalid or incomplete data received from watch.",
                    ackCode: .genericFailure
                )
            }

            if message[WatchMessageKeys.cancelOverride] as? Bool == true {
                info(.watch, "Watch requested override cancel")
                self.handleCancelOverride()
            }

            if let presetName = message[WatchMessageKeys.activateOverride] as? String {
                info(.watch, "Watch requested override preset \(presetName)")
                self.handleActivateOverride(presetName)
            }

            if let presetName = message[WatchMessageKeys.activateTempTarget] as? String {
                info(.watch, "Watch requested temp target preset \(presetName)")
                self.handleActivateTempTarget(presetName)
            }

            if message[WatchMessageKeys.cancelTempTarget] as? Bool == true {
                info(.watch, "Watch requested temp target cancel")
                self.handleCancelTempTarget()
            }

            if message[WatchMessageKeys.requestBolusRecommendation] as? Bool == true {
                let carbs = message[WatchMessageKeys.carbs] as? Int ?? 0

                var minPredBG: Decimal = BolusRecommendationGuard.veryLowGlucose

                Task { [weak self] in
                    guard let self = self else { return }

                    do {
                        let context = CoreDataStack.shared.newTaskContext()
                        context.name = "requestBolusRecommendation"
                        // Fetch determination data
                        let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                            predicate: NSPredicate.predicateFor30MinAgoForDetermination
                        )
                        let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared.getNSManagedObject(
                            with: determinationIds,
                            context: context
                        )

                        await MainActor.run {
                            minPredBG = determinationObjects.first?.minPredBGFromReason ?? BolusRecommendationGuard.veryLowGlucose
                        }

                    } catch let error as CoreDataError {
                        warning(.watch, "Fetching determination for watch bolus recommendation failed", error: error)
                    } catch {
                        warning(.watch, "Fetching determination for watch bolus recommendation failed", error: error)
                    }

                    // Get recommendation from BolusCalculationManager
                    let result = await bolusCalculationManager.handleBolusCalculation(
                        carbs: Decimal(carbs),
                        useFattyMealCorrection: false,
                        useSuperBolus: false,
                        lastLoopDate: apsManager.lastLoopDate,
                        minPredBG: minPredBG,
                        simulatedCOB: nil,
                        isBackdated: false // we cannot backdate carbs via watch
                    )

                    // Send recommendation back to watch
                    let recommendationMessage: [String: Any] = [
                        WatchMessageKeys.recommendedBolus: NSDecimalNumber(decimal: result.insulinCalculated)
                    ]

                    if let session = self.session, session.isReachable {
                        debug(.watch, "Sending recommended bolus \(result.insulinCalculated) U to watch")
                        session.sendMessage(recommendationMessage, replyHandler: nil)
                    }
                }
                return
            }
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let logs = userInfo["watchLogs"] as? String {
            WatchLogIngest.legacyRecords(from: logs).forEach(TrioLogger.sink.accept)
        }

        if let snoozeMinutes = userInfo[WatchMessageKeys.snoozeDuration] as? Int {
            info(.watch, "Watch requested alert snooze for \(snoozeMinutes) min")
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.notificationsManager.applySnooze(for: TimeInterval(snoozeMinutes * 60))
            }
        }
    }

    func session(_: WCSession, didReceive file: WCSessionFile) {
        WatchLogIngest.shared.receive(file.fileURL, metadata: file.metadata)
    }

    #if os(iOS)
        func sessionDidBecomeInactive(_: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }
    #endif

    func sessionReachabilityDidChange(_ session: WCSession) {
        debug(.watch, "Watch reachable: \(session.isReachable)")

        // A reachable watch asks for the state itself.
        guard !session.isReachable else { return }

        // Try to reconnect after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.retryConnection()
        }
    }

    /// Processes bolus requests received from the Watch
    /// - Parameters:
    ///   - amount: The requested bolus amount in units
    ///   - overriding: Safety checks the user has confirmed on the Watch to bolus through
    ///   - mealDate: The date of the carbs sent just before as part of the same entry, if any
    @MainActor private func handleBolusRequest(_ amount: Decimal, overriding: Set<BolusSafetyCheck>, mealDate: TimeInterval?) {
        Task {
            // The bolus was worked out for those carbs: none if they were refused or could not be saved.
            // Older Watch apps send no mealDate; their carbs come just before the bolus, so carbs received in the
            // last few seconds count as this bolus's carbs. A confirmation past a safety check comes much later.
            let carbsWereLogged: Bool
            if let mealDate {
                carbsWereLogged = await watchCarbsWereLogged(at: mealDate)
            } else if overriding.isEmpty, let recentCarbs = recentWatchCarbs(receivedWithin: Self.unpairedBolusWindow) {
                carbsWereLogged = await recentCarbs.value
            } else {
                carbsWereLogged = true
            }
            if !carbsWereLogged {
                info(.watch, "Watch bolus of \(amount) U refused: the carbs entered with it were not logged")
                sendAcknowledgment(
                    toWatch: false,
                    message: String(
                        localized: "Bolus not enacted: the carbs entered with it were not logged.",
                        comment: "Watch message when a bolus is refused because its carbs were refused or not saved"
                    ),
                    ackCode: .genericFailure
                )
                return
            }

            guard await passesBolusSafetyChecks(amount, overriding: overriding) else { return }

            await apsManager.enactBolus(amount: Double(amount), isSMB: false) { success, message in
                // Acknowledge success or error of bolus
                self.sendAcknowledgment(
                    toWatch: success,
                    message: message,
                    ackCode: success == true ? .genericSuccess : .genericFailure
                )
            }
            debug(.bolus, "Watch bolus of \(amount) U handed to APS manager")
        }
    }

    /// Runs the shared bolus safety checks (max bolus, max IOB, recent boluses) on a bolus requested from the Watch,
    /// and tells the Watch when one fails.
    ///
    /// A failed check the user may bolus through, like on the main bolus screen, is sent as `.bolusNeedsOverride`
    /// with the checks to send back if they confirm. Max bolus, and checks that cannot run, block the bolus.
    /// - Parameters:
    ///   - amount: The requested bolus amount in units
    ///   - overriding: Safety checks the user has already confirmed on the Watch to bolus through
    ///   - messagePrefix: Put in front of every message sent to the Watch, e.g. to say carbs were logged anyway
    /// - Returns: `true` if the bolus may be enacted
    private func passesBolusSafetyChecks(
        _ amount: Decimal,
        overriding: Set<BolusSafetyCheck>,
        messagePrefix: String? = nil
    ) async -> Bool {
        func prefixed(_ message: String) -> String {
            guard let messagePrefix else { return message }
            return "\(messagePrefix) \(message)"
        }

        let result: BolusSafetyResult
        do {
            result = try await bolusSafetyValidator.validate(bolusAmount: amount, overriding: overriding)
        } catch {
            warning(.watch, "Running bolus safety checks for watch bolus failed", error: error)
            sendAcknowledgment(
                toWatch: false,
                message: prefixed(String(
                    localized: "Bolus blocked: the safety checks could not be completed.",
                    comment: "Error message sent to watch when the bolus safety checks fail to run"
                )),
                ackCode: .genericFailure
            )
            return false
        }

        guard case let .rejected(reason) = result else {
            if !overriding.isEmpty {
                info(.watch, "User confirmed watch bolus past safety checks: \(overriding.map(\.rawValue).sorted())")
            }
            return true
        }

        let message = reason.localizedMessage(requestedAmount: amount)
        guard reason.check.canBeOverridden else {
            info(.watch, "Watch bolus of \(amount) U rejected: \(message)")
            sendAcknowledgment(toWatch: false, message: prefixed(message), ackCode: .genericFailure)
            return false
        }

        info(.watch, "Asking watch to confirm bolus of \(amount) U past safety check: \(message)")
        sendAcknowledgment(
            toWatch: false,
            message: prefixed(message),
            ackCode: .bolusNeedsOverride,
            details: [
                WatchMessageKeys.bolus: NSDecimalNumber(decimal: amount),
                WatchMessageKeys.overriddenBolusChecks: overriding.union([reason.check]).map(\.rawValue).sorted(),
                WatchMessageKeys.bolusOverrideIssuedAt: Date().timeIntervalSince1970
            ]
        )
        return false
    }

    /// Reads the safety checks a Watch bolus request says the user confirmed to bolus through. An expired
    /// confirmation is dropped, so every check runs again on current data and the Watch asks again if one still fails.
    private func overriddenBolusChecks(in message: [String: Any]) -> Set<BolusSafetyCheck> {
        let rawValues = message[WatchMessageKeys.overriddenBolusChecks] as? [String] ?? []
        guard !rawValues.isEmpty else { return [] }

        let overriding = BolusSafetyCheck.overridden(
            rawValues,
            issuedAt: message[WatchMessageKeys.bolusOverrideIssuedAt] as? TimeInterval
        )
        if overriding.isEmpty {
            info(.watch, "Expired watch confirmation past safety checks ignored: \(rawValues)")
        }
        return overriding
    }

    /// Handles carbs entry requests received from the Watch
    /// - Parameters:
    ///   - amount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    @MainActor private func handleCarbsRequest(_ amount: Int, _ date: Date) {
        let outcome = Task { () -> Bool in
            let carbs = Decimal(amount)
            if let rejection = Self.watchCarbsRejection(carbs: carbs, maxCarbs: settingsManager.settings.maxCarbs) {
                info(.watch, "Watch carbs of \(amount) g rejected: \(rejection)")
                sendAcknowledgment(toWatch: false, message: rejection, ackCode: .genericFailure)
                return false
            }

            guard await storeWatchCarbs(carbs, date: date) else {
                sendAcknowledgment(toWatch: false, message: Self.carbsNotSavedMessage, ackCode: .genericFailure)
                return false
            }
            sendAcknowledgment(
                toWatch: true,
                message: String(
                    localized: "Carbs logged successfully.",
                    comment: "Success message sent to watch when carbs are logged successfully"
                ),
                ackCode: .carbsLogged
            )
            Task { await self.updateDeterminationAfterWatchCarbs() }
            return true
        }

        // A bolus sent with these carbs looks up whether they were logged
        let now = Date().timeIntervalSince1970
        watchCarbsOutcomes = watchCarbsOutcomes.filter { now - $0.key < Self.watchCarbsOutcomeLifetime }
        watchCarbsOutcomes[date.timeIntervalSince1970] = outcome
        lastWatchCarbs = (receivedAt: Date(), outcome: outcome)
    }

    /// How recently carbs must have been received for a bolus without a mealDate to be treated as theirs.
    static let unpairedBolusWindow: TimeInterval = 5

    /// The outcome of the last Watch carbs, if they were received within `window`.
    @MainActor private func recentWatchCarbs(receivedWithin window: TimeInterval) -> Task<Bool, Never>? {
        guard let lastWatchCarbs, Date().timeIntervalSince(lastWatchCarbs.receivedAt) <= window else { return nil }
        return lastWatchCarbs.outcome
    }

    /// How long the outcome of Watch carbs is kept for the bolus sent with them.
    private static let watchCarbsOutcomeLifetime: TimeInterval = 5 * 60
    /// How long a bolus waits for the carbs sent just before it, which may still be on their way.
    private static let watchCarbsArrivalWait: TimeInterval = 5

    /// Whether the Watch carbs dated `mealDate` were logged. Waits briefly for carbs not received yet;
    /// carbs that never arrive count as not logged, so their bolus is not given either.
    @MainActor private func watchCarbsWereLogged(at mealDate: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.watchCarbsArrivalWait)
        while watchCarbsOutcomes[mealDate] == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let outcome = watchCarbsOutcomes[mealDate] else {
            warning(.watch, "Carbs for a watch bolus never arrived")
            return false
        }
        return await outcome.value
    }

    /// Handles combined bolus and carbs entry requests received from the Watch.
    ///
    /// Older Watch apps send carbs and bolus in one message. The carbs are saved first; the final acknowledgment
    /// tells the Watch whether the bolus was enacted too, so a blocked or failed bolus is never shown as success.
    /// - Parameters:
    ///   - bolusAmount: The bolus amount in units
    ///   - carbsAmount: The carbs amount in grams
    ///   - date: Timestamp for the carbs entry
    ///   - overriding: Safety checks the user has confirmed on the Watch to bolus through
    private func handleCombinedRequest(
        bolusAmount: Decimal,
        carbsAmount: Decimal,
        date: Date,
        overriding: Set<BolusSafetyCheck>
    ) {
        Task {
            // The bolus was worked out for these carbs, so neither is logged when the carbs are refused
            if let rejection = Self.watchCarbsRejection(carbs: carbsAmount, maxCarbs: settingsManager.settings.maxCarbs) {
                info(.watch, "Watch carbs of \(carbsAmount) g with bolus rejected: \(rejection)")
                sendAcknowledgment(
                    toWatch: false,
                    message: String(
                        localized: "Nothing logged, no bolus enacted: \(rejection)",
                        comment: "Watch message when a carbs and bolus entry is refused; the argument is the reason"
                    ),
                    ackCode: .genericFailure
                )
                return
            }

            // Notify Watch: "Saving carbs..."
            sendAcknowledgment(
                toWatch: true,
                message: String(
                    localized: "Saving Carbs...",
                    comment: "Successful message sent to watch when saving carbs"
                ),
                ackCode: .savingCarbs
            )

            // No bolus for carbs that were not saved
            guard await storeWatchCarbs(carbsAmount, date: date) else {
                sendAcknowledgment(
                    toWatch: false,
                    message: "\(Self.carbsNotSavedMessage) \(String(localized: "No bolus enacted.", comment: "Watch message added when a bolus was not given because its carbs could not be saved"))",
                    ackCode: .genericFailure
                )
                return
            }

            let carbsLoggedPrefix = String(
                localized: "Carbs logged, bolus not enacted.",
                comment: "Start of the watch message when carbs were saved but the bolus was not given"
            )

            // The carbs stay logged if the bolus is blocked or needs the user to confirm it
            guard await passesBolusSafetyChecks(bolusAmount, overriding: overriding, messagePrefix: carbsLoggedPrefix) else {
                await updateDeterminationAfterWatchCarbs()
                return
            }

            // Notify Watch: "Enacting bolus..."
            sendAcknowledgment(
                toWatch: true,
                message: String(
                    localized: "Enacting bolus...",
                    comment: "Successful message sent to watch when enacting bolus"
                ),
                ackCode: .enactingBolus
            )

            // Enact bolus via APS Manager and wait for how it ended
            let bolusDouble = NSDecimalNumber(decimal: bolusAmount).doubleValue
            var bolusResult: BolusEnactmentResult?
            await apsManager.enactBolus(amount: bolusDouble, isSMB: false) { (result: BolusEnactmentResult) in
                bolusResult = result
            }
            debug(.bolus, "Watch bolus of \(bolusDouble) U with carbs handed to APS manager")

            if let bolusResult, bolusResult.isSuccess {
                // A manual bolus runs its own determination, which picks up the carbs too
                sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Carbs and Bolus logged successfully.",
                        comment: "Successful message sent to watch when logging carbs and bolus"
                    ),
                    ackCode: .comboComplete
                )
            } else {
                let reason = bolusResult?.message ?? String(
                    localized: "Bolus status unknown. Check pump history before repeating.",
                    comment: "Watch message when the outcome of a bolus is not known"
                )
                warning(.watch, "Watch bolus with carbs not enacted: \(reason)")
                sendAcknowledgment(
                    toWatch: false,
                    message: "\(String(localized: "Carbs logged.", comment: "Start of the watch message when carbs were saved but the bolus failed")) \(reason)",
                    ackCode: .genericFailure
                )
                await updateDeterminationAfterWatchCarbs()
            }
        }
    }

    /// Returns why carbs from the Watch may not be logged, or `nil` if they may.
    ///
    /// Carbs above the max carbs setting are refused rather than capped: the user, and any bolus worked out on the Watch,
    /// expect the amount that was entered.
    static func watchCarbsRejection(carbs: Decimal, maxCarbs: Decimal) -> String? {
        guard carbs > 0 else {
            return String(
                localized: "Carbs must be more than 0 g.",
                comment: "Watch message when a carbs entry of zero or less is received"
            )
        }
        guard carbs <= maxCarbs else {
            return String(
                localized: "\(carbs.formatted()) g is more than the max carbs of \(maxCarbs.formatted()) g.",
                comment: "Watch message when carbs above the max carbs setting are refused"
            )
        }
        return nil
    }

    /// The carb entry stored for carbs logged on the Watch.
    static func watchCarbsEntry(carbs: Decimal, date: Date) -> CarbsEntry {
        CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: date,
            carbs: carbs,
            fat: 0,
            protein: 0,
            note: String(localized: "Via Watch", comment: "Note added to carb entry when entered via watch"),
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: nil
        )
    }

    static let carbsNotSavedMessage = String(
        localized: "Error! Carbs could not be saved.",
        comment: "Watch message when carbs from the watch could not be saved"
    )

    /// Saves Watch carbs through `CarbsStorage`, the same path the Treatments screen uses.
    /// - Returns: `true` if the carbs were saved.
    private func storeWatchCarbs(_ carbs: Decimal, date: Date) async -> Bool {
        do {
            try await carbsStorage.storeCarbs([Self.watchCarbsEntry(carbs: carbs, date: date)], areFetchedFromRemote: false)
            info(.treatments, "Saved \(carbs) g carbs from watch")
            return true
        } catch {
            warning(.treatments, "Saving carbs from watch failed", error: error)
            return false
        }
    }

    /// Runs a determination so COB and the forecast include carbs just logged from the Watch,
    /// like the Treatments screen does when no bolus follows.
    private func updateDeterminationAfterWatchCarbs() async {
        do {
            try await apsManager.determineBasalSync()
        } catch {
            warning(.loop, "Determination after watch carbs failed", error: error)
        }
    }

    private func handleCancelOverride() {
        Task {
            do {
                let outcome = try await adjustmentManager.cancelOverride(source: .watch)
                debug(.treatments, "Override \"\(outcome.ended.first?.name ?? "Custom Override")\" stopped from watch")

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Stopped Override successfully.",
                        comment: "Stopped Override successfully"
                    ),
                    ackCode: .overrideStopped
                )
            } catch {
                warning(.treatments, "Stopping override from watch failed", error: error)
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error stopping Override.",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleActivateOverride(_ presetName: String) {
        Task {
            do {
                let outcome = try await adjustmentManager.activateOverride(.presetName(presetName), source: .watch)
                debug(.treatments, "Override \(presetName) started from watch")
                if let ended = outcome.ended.first {
                    debug(.treatments, "Recorded run for replaced override \"\(ended.name ?? "Custom Override")\"")
                }

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Started Override \"\(presetName)\" successfully.",
                        comment: "Start override with override name"
                    ),
                    ackCode: .overrideStarted
                )
            } catch {
                warning(.treatments, "Starting override from watch failed", error: error)
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error activating Override \"\(presetName)\".",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleActivateTempTarget(_ presetName: String) {
        Task {
            do {
                let outcome = try await adjustmentManager.activateTempTarget(.presetName(presetName), source: .watch)
                debug(.treatments, "Temp target \(presetName) started from watch")
                if let ended = outcome.ended.first {
                    debug(.treatments, "Recorded run for replaced temp target \"\(ended.name ?? "Temp Target")\"")
                }

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Started Temp Target \"\(presetName)\" successfully.",
                        comment: "Started Temp Target successfully."
                    ),
                    ackCode: .tempTargetStarted
                )
            } catch {
                warning(.treatments, "Starting temp target from watch failed", error: error)
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error activating Temp Target \"\(presetName)\".",
                    ackCode: .genericFailure
                )
            }
        }
    }

    private func handleCancelTempTarget() {
        Task {
            do {
                let outcome = try await adjustmentManager.cancelTempTarget(source: .watch)
                debug(.treatments, "Temp target \"\(outcome.ended.first?.name ?? "Temp Target")\" stopped from watch")

                self.sendAcknowledgment(
                    toWatch: true,
                    message: String(
                        localized: "Stopped Temp Target successfully.",
                        comment: "Stopped Temp Target successfully."
                    ),
                    ackCode: .tempTargetStopped
                )
            } catch {
                warning(.treatments, "Stopping temp target from watch failed", error: error)
                self.sendAcknowledgment(
                    toWatch: false,
                    message: (error as? AdjustmentError)?.errorDescription ?? "Error stopping Temp Target.",
                    ackCode: .genericFailure
                )
            }
        }
    }
}

// TODO: - is there a better approach than setting up the watch state every time a setting has changed?
extension BaseWatchManager: SettingsObserver, PumpSettingsObserver {
    // to update maxBolus
    func pumpSettingsDidChange(_: PumpSettings) {
        scheduleWatchStatePush()
    }

    // to update the rest
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
        glucoseColorScheme = settingsManager.settings.glucoseColorScheme
        lowGlucose = settingsManager.settings.low
        highGlucose = settingsManager.settings.high

        scheduleWatchStatePush()
    }
}

extension BaseWatchManager: SnoozeObserver {
    @MainActor func snoozeDidChange(_: Date) {
        Task { await self.pushWatchState() }
    }
}

extension BaseWatchManager {
    /// Retrieves the current glucose target based on the time of day.
    private func getCurrentGlucoseTarget() async -> Decimal? {
        let now = Date()
        let calendar = Calendar.current

        let bgTargets = await fileStorage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
            ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        let entries: [(start: String, value: Decimal)] = bgTargets.targets.map { ($0.start, $0.low) }

        for (index, entry) in entries.enumerated() {
            guard let entryTime = TherapySettingsUtil.parseTime(entry.start) else {
                warning(.watch, "Skipped glucose target with invalid start time \(entry.start)")
                continue
            }

            let entryComponents = calendar.dateComponents([.hour, .minute, .second], from: entryTime)
            let entryStartTime = calendar.date(
                bySettingHour: entryComponents.hour!,
                minute: entryComponents.minute!,
                second: entryComponents.second!,
                of: now
            )!

            let entryEndTime: Date
            if index < entries.count - 1,
               let nextEntryTime = TherapySettingsUtil.parseTime(entries[index + 1].start)
            {
                let nextEntryComponents = calendar.dateComponents([.hour, .minute, .second], from: nextEntryTime)
                entryEndTime = calendar.date(
                    bySettingHour: nextEntryComponents.hour!,
                    minute: nextEntryComponents.minute!,
                    second: nextEntryComponents.second!,
                    of: now
                )!
            } else {
                entryEndTime = calendar.date(byAdding: .day, value: 1, to: entryStartTime)!
            }

            if now >= entryStartTime, now < entryEndTime {
                return entry.value
            }
        }

        return nil
    }
}

extension BaseWatchManager {
    enum AcknowledgmentCode: String, Codable {
        case savingCarbs = "saving_carbs"
        case enactingBolus = "enacting_bolus"
        case comboComplete = "combo_complete"
        case carbsLogged = "carbs_logged"
        case overrideStarted = "override_started"
        case overrideStopped = "override_stopped"
        case tempTargetStarted = "temp_target_started"
        case tempTargetStopped = "temp_target_stopped"
        case genericSuccess = "success"
        case genericFailure = "failure"
        /// A bolus failed a safety check the user may confirm on the Watch to bolus through.
        case bolusNeedsOverride = "bolus_needs_override"
    }
}
