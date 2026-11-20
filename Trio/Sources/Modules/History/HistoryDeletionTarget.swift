import CoreData
import Foundation

extension History {
    enum DeletionTarget: Identifiable {
        case glucose(GlucoseStored)
        case insulin(PumpEventStored)
        case carbs(CarbEntryStored)

        var id: NSManagedObjectID {
            switch self {
            case let .glucose(glucose): return glucose.objectID
            case let .insulin(pumpEvent): return pumpEvent.objectID
            case let .carbs(carbEntry): return carbEntry.objectID
            }
        }

        func title(units _: GlucoseUnits) -> String {
            switch self {
            case .glucose:
                return String(localized: "Delete Glucose?", comment: "Alert title for deleting glucose")
            case .insulin:
                return String(localized: "Delete Insulin?", comment: "Alert title for deleting insulin")
            case let .carbs(carbEntry):
                if carbEntry.fpuID == nil {
                    return String(localized: "Delete Carbs?", comment: "Alert title for deleting carbs")
                }
                return carbEntry.isFPU
                    ? String(localized: "Delete Carbs Equivalents?", comment: "Alert title for deleting carb equivalents")
                    : String(localized: "Delete Carbs?", comment: "Alert title for deleting carbs")
            }
        }

        /// How long after their time carbs still count towards COB in oref (it looks back 6 hours).
        static let carbsActiveDuration: TimeInterval = 6 * 60 * 60

        /// - Parameters:
        ///   - insulinActiveDuration: The insulin's duration of action; insulin given within it still counts towards IOB.
        ///   - now: The current time.
        func message(units: GlucoseUnits, insulinActiveDuration: TimeInterval, now: Date = Date()) -> String? {
            switch self {
            case let .glucose(glucose):
                let glucoseToDisplay = Decimal(glucose.glucose).formatted(for: units)
                return Formatter.dateFormatter.string(from: glucose.date ?? Date())
                    + ", " + glucoseToDisplay + " " + units.rawValue
            case let .insulin(pumpEvent):
                var text = Formatter.dateFormatter.string(from: pumpEvent.timestamp ?? Date())
                    + ", "
                    + (pumpEvent.bolus?.amount?.decimalValue ?? 0).formatted(.insulin)
                    + String(localized: " U", comment: "Insulin unit")
                if let bolus = pumpEvent.bolus, bolus.isSMB {
                    text += String(localized: " SMB", comment: "Super Micro Bolus indicator in delete alert")
                }
                if let warning = insulinWarning(for: pumpEvent, activeDuration: insulinActiveDuration, now: now) {
                    text += "\n\n" + warning
                }
                return text
            case let .carbs(carbEntry):
                var text: String
                if carbEntry.fpuID == nil {
                    text = Formatter.dateFormatter.string(from: carbEntry.date ?? Date())
                        + ", "
                        + (Formatter.decimalFormatterWithTwoFractionDigits.string(for: carbEntry.carbs) ?? "0")
                        + String(localized: " g", comment: "gram of carbs")
                } else {
                    text = String(
                        localized: "All FPUs and the carbs of the meal will be deleted.",
                        comment: "Alert message for meal deletion"
                    )
                }
                if let warning = carbsWarning(for: carbEntry, now: now) {
                    text += "\n\n" + warning
                }
                return text
            }
        }

        /// Explains what deleting insulin that still acts does, depending on how it was given; `nil` once it no longer acts.
        private func insulinWarning(for pumpEvent: PumpEventStored, activeDuration: TimeInterval, now: Date) -> String? {
            guard let bolus = pumpEvent.bolus, let timestamp = pumpEvent.timestamp,
                  now.timeIntervalSince(timestamp) < activeDuration
            else { return nil }

            if bolus.isExternal {
                return String(
                    localized: "This insulin is still active. Deleting it lowers IOB, so Trio may dose more insulin. Only delete it if it was not actually taken.",
                    comment: "Warning when deleting external insulin that is still active"
                )
            }
            if bolus.isSMB {
                return String(
                    localized: "This SMB was delivered by the pump and is still active. Deleting it does not undo the delivery, but it lowers IOB, so Trio may dose more insulin than is safe.",
                    comment: "Warning when deleting an SMB that is still active"
                )
            }
            return String(
                localized: "This bolus was delivered by the pump and is still active. Deleting it does not undo the delivery, but it lowers IOB, so Trio may dose more insulin than is safe.",
                comment: "Warning when deleting a pump bolus that is still active"
            )
        }

        /// Explains what deleting carbs that still count towards COB does; `nil` once they no longer count.
        private func carbsWarning(for carbEntry: CarbEntryStored, now: Date) -> String? {
            guard let date = carbEntry.date, now.timeIntervalSince(date) < Self.carbsActiveDuration else { return nil }
            return String(
                localized: "These carbs still count towards COB. Deleting them lowers COB, so Trio will dose less insulin for them.",
                comment: "Warning when deleting carbs that are still being absorbed"
            )
        }
    }
}
