import CoreData
import LoopKit
import Observation
import SwiftDate
import SwiftUI

extension Calibrations {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var glucoseStorage: GlucoseStorage!
        @ObservationIgnored @Injected() var calibrationService: CalibrationService!
        @ObservationIgnored @Injected() var trioAlertManager: TrioAlertManager!

        var slope: Double = 1
        var intercept: Double = 1
        var newCalibration: Decimal = 0
        var calibrations: [Calibration] = []
        var calibrate: (Int) -> Double = { Double($0) }
        var items: [Item] = []

        var units: GlucoseUnits = .mgdL

        let backgroundContext = CoreDataStack.shared.newTaskContext()
        private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

        override func subscribe() {
            units = settingsManager.settings.units
            calibrate = calibrationService.calibrate
            setupCalibrations()
        }

        private func setupCalibrations() {
            slope = calibrationService.slope
            intercept = calibrationService.intercept
            calibrations = calibrationService.calibrations
            items = calibrations.map {
                Item(calibration: $0)
            }
        }

        /// - Returns: An array of NSManagedObjectIDs for glucose readings.
        private func fetchGlucose() async throws -> [NSManagedObjectID] {
            try await CoreDataStack.shared.fetchObjectIDs(
                ofType: GlucoseStored.self,
                onContext: backgroundContext,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate.predicateFor20MinAgo,
                    NSPredicate.cgmGlucose,
                    NSPredicate.glucoseNotInFuture
                ]),
                key: "date",
                ascending: false,
                fetchLimit: 1 /// We only need the last value
            )
        }

        @MainActor func addCalibration() async {
            do {
                defer {
                    UIApplication.shared.endEditing()
                    setupCalibrations()
                }

                var glucose = newCalibration
                if units == .mmolL {
                    glucose = newCalibration.asMgdL
                }

                let glucoseValuesIds = try await fetchGlucose()
                let glucoseObjects: [GlucoseStored] = try await CoreDataStack.shared
                    .getNSManagedObject(with: glucoseValuesIds, context: viewContext)

                guard let lastGlucose = glucoseObjects.first, let readingDate = lastGlucose.date else {
                    debug(.cgm, "Calibration not added, no recent glucose")
                    issueCalibrationAlert(
                        identifier: "glucose.stale",
                        body: String(localized: "Glucose is stale for calibration")
                    )
                    return
                }

                switch Self.validateCalibration(
                    readingDate: readingDate,
                    rawValue: calibrationService.rawValue(
                        forStoredGlucose: Int(lastGlucose.glucose),
                        readingDate: readingDate
                    ),
                    existing: calibrationService.calibrations
                ) {
                case let .valid(raw):
                    let calibration = Calibration(x: raw, y: Double(glucose), readingDate: readingDate)
                    calibrationService.addCalibration(calibration)
                    info(.cgm, "Calibration added: BG \(glucose) mg/dL, sensor raw \(raw) mg/dL at \(readingDate)")
                case .readingAlreadyCalibrated:
                    debug(.cgm, "Calibration not added, the reading at \(readingDate) already has a calibration")
                    issueCalibrationAlert(
                        identifier: "reading.duplicate",
                        body: String(
                            localized: "This sensor reading already has a calibration. Wait for the next sensor reading, or remove the existing calibration first."
                        )
                    )
                case .rawValueUnknown:
                    debug(.cgm, "Calibration not added, raw value of the reading at \(readingDate) is unknown")
                    issueCalibrationAlert(
                        identifier: "raw.unknown",
                        body: String(
                            localized: "Calibrations changed since the last sensor reading. Wait for the next sensor reading."
                        )
                    )
                }
            } catch {
                warning(.cgm, "Adding calibration failed", error: error)
            }
        }

        enum CalibrationValidation: Equatable {
            case valid(raw: Double)
            /// A calibration against the same sensor reading already exists. Two
            /// calibrations sharing one x can't define a slope.
            case readingAlreadyCalibrated
            case rawValueUnknown
        }

        /// Pairs a fingerstick with the uncalibrated value of the latest sensor reading.
        static func validateCalibration(
            readingDate: Date,
            rawValue: Double?,
            existing: [Calibration]
        ) -> CalibrationValidation {
            if existing.contains(where: { $0.readingDate.map { abs($0.timeIntervalSince(readingDate)) < 1 } ?? false }) {
                return .readingAlreadyCalibrated
            }
            guard let rawValue, rawValue.isFinite else { return .rawValueUnknown }
            return .valid(raw: rawValue)
        }

        /// Surfaces why a calibration wasn't added as a one-shot info alert
        /// through `TrioAlertManager`.
        private func issueCalibrationAlert(identifier: String, body: String) {
            let content = Alert.Content(
                title: String(localized: "Calibration unavailable"),
                body: body,
                acknowledgeActionButtonLabel: String(localized: "OK")
            )
            let alert = Alert(
                identifier: Alert.Identifier(
                    managerIdentifier: "trio.calibration",
                    alertIdentifier: identifier
                ),
                foregroundContent: content,
                backgroundContent: content,
                trigger: .immediate,
                interruptionLevel: .active,
                sound: nil
            )
            trioAlertManager?.issueAlert(alert)
        }

        func removeLast() {
            calibrationService.removeLast()
            setupCalibrations()
        }

        func removeAll() {
            calibrationService.removeAllCalibrations()
            setupCalibrations()
        }

        func removeAtIndex(_ index: Int) {
            let calibration = calibrations[index]
            calibrationService.removeCalibration(calibration)
            setupCalibrations()
        }
    }
}
