import CoreData
import Foundation

final class CarbPresetIntentRequest: BaseIntentsRequest {
    func addCarbs(
        _ quantityCarbs: Int,
        _ quantityFat: Int,
        _ quantityProtein: Int,
        _ dateAdded: Date,
        _ note: String?,
        _ dateDefinedByUser: Bool
    ) async throws -> String {
        guard quantityCarbs >= 0, quantityFat >= 0, quantityProtein >= 0,
              quantityCarbs > 0 || quantityFat > 0 || quantityProtein > 0
        else {
            return String(localized: "Amount must be positive.")
        }

        try await carbsStorage.storeCarbs(
            [CarbsEntry(
                id: UUID().uuidString,
                createdAt: dateAdded,
                actualDate: dateAdded,
                carbs: Decimal(quantityCarbs),
                fat: Decimal(quantityFat),
                protein: Decimal(quantityProtein),
                note: (note?.isEmpty ?? true) ? "Via Shortcut" : note!,
                enteredBy: CarbsEntry.local,
                isFPU: false,
                // Links the meal to the carb equivalents made from its fat and protein, so deleting it removes them too
                fpuID: quantityFat > 0 || quantityProtein > 0 ? UUID().uuidString : nil
            )],
            areFetchedFromRemote: false
        )
        // Like the Treatments screen, update COB and the forecast for the new carbs right away
        do {
            try await apsManager.determineBasalSync()
        } catch {
            warning(.treatments, "Determination after Shortcut carbs failed", error: error)
        }
        var resultDisplay: String
        resultDisplay = String(localized: "Added \(quantityCarbs) g carbs")
        if quantityFat > 0 {
            resultDisplay = String(localized: "\(resultDisplay) and \(quantityFat) g fat")
        }
        if quantityProtein > 0 {
            resultDisplay = String(localized: "\(resultDisplay) and \(quantityProtein) g protein")
        }
        if dateDefinedByUser {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .none
            dateFormatter.timeStyle = .short

            let hourName = dateFormatter.string(from: dateAdded)
            resultDisplay = String(localized: "\(resultDisplay) at \(hourName)")

            let dayStatus = determineDateStatus(dateAdded)
            if let dayStatus = dayStatus {
                resultDisplay = String(localized: "\(resultDisplay)  \(dayStatus)")
            }
        }

        return resultDisplay
    }

    func determineDateStatus(_ date: Date) -> LocalizedStringResource? {
        let calendar = Calendar.current
        let now = Date()

        let dateStartOfDay = calendar.startOfDay(for: date)
        let nowStartOfDay = calendar.startOfDay(for: now)

        let components = calendar.dateComponents([.day], from: nowStartOfDay, to: dateStartOfDay)

        if let dayDifference = components.day {
            switch dayDifference {
            case -1:
                return LocalizedStringResource(stringLiteral: "Yesterday")
            case 0:
                return nil
            case 1:
                return LocalizedStringResource(stringLiteral: "Tomorrow")
            default:
                return nil
            }
        }
        return nil
    }
}
