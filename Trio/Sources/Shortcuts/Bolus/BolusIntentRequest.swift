import Combine
import CoreData
import Foundation

final class BolusIntentRequest: BaseIntentsRequest {
    /// The amount the pump will actually deliver for `amount`: rounded to a bolus volume the pump supports.
    ///
    /// Not capped at max bolus, so the user confirms the amount they asked for and the safety checks refuse it if too large.
    func deliverableAmount(_ amount: Double) -> Decimal {
        guard amount > 0 else { return 0 }
        guard let pump = apsManager.pumpManager else { return Decimal(amount).rounded(scale: 3) }
        return Decimal(pump.roundToSupportedBolusVolume(units: amount)).rounded(scale: 3)
    }

    /// The amount of external insulin that will be logged: rounded down to the bolus increment, without the pump's
    /// largest-volume cap, which would under-report insulin taken by pen.
    func externalAmount(_ amount: Double) -> Decimal {
        ExternalInsulin.rounded(Decimal(amount).rounded(scale: 3), toIncrement: settingsManager.preferences.bolusIncrement)
    }

    /// The confirmation question shown before a Shortcut bolus, naming the amount that will really be delivered or logged.
    /// - Parameter maxBolus: Set when external insulin above max bolus is confirmed, to warn about it.
    static func confirmationMessage(
        requested: Double,
        deliverable: Decimal,
        isExternal: Bool,
        aboveMaxBolus maxBolus: Decimal? = nil
    ) -> String {
        let deliverableFormatted = deliverable.formatted()
        var message = isExternal
            ? String(localized: "Are you sure to log \(deliverableFormatted) U of external insulin?")
            : String(localized: "Are you sure to bolus \(deliverableFormatted) U of insulin?")
        if deliverable != Decimal(requested).rounded(scale: 3) {
            let requestedFormatted = Decimal(requested).rounded(scale: 3).formatted()
            message += " " + (
                isExternal
                    ? String(
                        localized: "\(requestedFormatted) U was rounded down to the bolus increment.",
                        comment: "Added to the Shortcut external insulin confirmation when the amount is rounded to the bolus increment"
                    )
                    : String(
                        localized: "\(requestedFormatted) U was rounded down to what the pump can deliver.",
                        comment: "Added to the Shortcut bolus confirmation when the requested amount is rounded to the pump's increment"
                    )
            )
        }
        if let maxBolus {
            message += " " + String(
                localized: "This is more than your max bolus of \(maxBolus.formatted()) U. Check the amount before logging it.",
                comment: "Added to the Shortcut confirmation for external insulin above max bolus"
            )
        }
        return message
    }

    /// The Shortcut result for a bolus, based on how the pump command actually ended.
    static func resultMessage(for result: BolusEnactmentResult?, amount: Decimal) -> String {
        let amountFormatted = amount.formatted()
        switch result {
        case .enacted:
            return String(
                localized: "A bolus of \(amountFormatted) U of insulin was enacted.",
                comment: "Shortcut result when the pump confirmed the bolus"
            )
        case let .failed(message, _):
            return String(
                localized: "Bolus of \(amountFormatted) U not delivered. \(message)",
                comment: "Shortcut result when the bolus was refused or failed; the second argument is the reason"
            )
        case let .uncertainDelivery(message, _):
            return String(
                localized: "The pump did not confirm the bolus of \(amountFormatted) U, it may have been delivered. Check pump history before repeating. \(message)",
                comment: "Shortcut result when it is not known whether the bolus was delivered; the second argument is the reason"
            )
        case .none:
            return String(
                localized: "The outcome of the bolus of \(amountFormatted) U is not known. Check pump history before repeating.",
                comment: "Shortcut result when no outcome was reported for the bolus"
            )
        }
    }

    func bolus(_ bolusAmount: Double) async throws -> String {
        switch settingsManager.settings.bolusShortcut {
        case .notAllowed:
            return String(
                localized:
                "Bolusing via Shortcuts is disabled in Trio settings."
            )

        case .limitWithSafetyChecks:
            let requestedAmount = Decimal(bolusAmount)
            let validation = try await bolusSafetyValidator.validate(bolusAmount: requestedAmount)

            if case let .rejected(reason) = validation {
                return reason.localizedMessage(requestedAmount: requestedAmount)
            }

            let bolusQuantity = apsManager.roundBolus(amount: requestedAmount)
            var enactmentResult: BolusEnactmentResult?
            await apsManager.enactBolus(amount: Double(bolusQuantity), isSMB: false) { (result: BolusEnactmentResult) in
                enactmentResult = result
            }
            if enactmentResult?.isSuccess != true {
                warning(.bolus, "Shortcut bolus of \(bolusQuantity) U not enacted: \(enactmentResult?.message ?? "no result")")
            }
            return Self.resultMessage(for: enactmentResult, amount: bolusQuantity.rounded(scale: 3))
        }
    }

    func bolusExternal(_ bolusAmount: Double) async throws -> String {
        var maxExternal: Decimal { settingsManager.pumpSettings.maxBolus * 3 }
        if Decimal(bolusAmount) > maxExternal {
            return String(
                localized:
                "The external bolus cannot be larger than 3 x the pump setting max bolus (\(settingsManager.pumpSettings.maxBolus.description))."
            )
        } else {
            // Rounded to the increment but not capped: external insulin up to 3 x max bolus is logged in full
            let bolusQuantity = externalAmount(bolusAmount)
            await pumpHistoryStorage.storeExternalInsulinEvent(amount: bolusQuantity, timestamp: Date())
            // perform determine basal sync
            do {
                try await apsManager.determineBasalSync()
            } catch {
                warning(.bolus, "Determination after Shortcut external insulin failed", error: error)
                return ExternalInsulin.loggedButForecastFailedMessage(amount: bolusQuantity, error: error)
            }

            return String(
                localized:
                "An external bolus of \(bolusQuantity.formatted()) U of insulin was recorded."
            )
        }
    }
}
