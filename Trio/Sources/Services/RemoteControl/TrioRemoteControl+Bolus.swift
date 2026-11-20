import Foundation
import HealthKit

extension TrioRemoteControl {
    func handleBolusCommand(_ payload: CommandPayload) async throws {
        guard let bolusAmount = payload.bolusAmount else {
            await logError("Command rejected: bolus amount is missing or invalid.", payload: payload)
            return
        }

        if let rejection = try await bolusLimitRejection(bolusAmount: bolusAmount) {
            await logError(rejection, payload: payload)
            return
        }

        if let rejection = try await treatmentGuardRejection(for: payload, bolusAmount: bolusAmount, checkCarbs: false) {
            await logError(rejection, payload: payload)
            return
        }

        await enactRemoteBolus(payload, bolusAmount: bolusAmount)
    }

    /// Max bolus and max IOB rejection message, or nil when the amount is within limits. A bolus in progress on the
    /// pump and a remote bolus sent but not yet reported count toward IOB; one that is also stored already is counted
    /// twice, which can only make the check stricter.
    func bolusLimitRejection(bolusAmount: Decimal) async throws -> String? {
        let pumpBolus = pumpBolusInProgress()
        let pending = RemoteTreatmentGuard.activePendingBolus(
            pendingRemoteBolus,
            stored: [],
            pumpBolusInProgress: pumpBolus,
            now: Date()
        )
        let unrecorded = (pumpBolus?.units ?? 0) + (pending?.units ?? 0)
        switch try await bolusSafetyValidator.validateLimits(bolusAmount: bolusAmount, unrecordedUnits: unrecorded) {
        case .allowed:
            return nil
        case let .rejected(reason):
            return reason.remoteCommandMessage(bolusAmount: bolusAmount)
        }
    }

    /// Hands the bolus to the pump. `carbsStored` tells the sender in a failure reply that the meal's carbs are stored.
    func enactRemoteBolus(_ payload: CommandPayload, bolusAmount: Decimal, carbsStored: Bool = false) async {
        debug(.remote, "Enacting remote bolus of \(bolusAmount) U")

        if let returnInfo = payload.returnNotification {
            await RemoteNotificationResponseManager.shared.sendResponseNotification(
                to: returnInfo,
                commandType: payload.commandType,
                success: true,
                message: "Initiating bolus..."
            )
        }

        let pending = RemoteTreatmentGuard.InFlightBolus(
            date: Date(),
            units: Self.pendingBolusUnits(
                requested: bolusAmount,
                roundToSupportedVolume: apsManager.pumpManager.map { pump in
                    { pump.roundToSupportedBolusVolume(units: $0) }
                }
            ),
            syncIdentifier: nil
        )
        pendingRemoteBolus = pending

        await apsManager
            .enactBolus(
                amount: Double(truncating: bolusAmount as NSNumber),
                isSMB: false
            ) { [weak self] (result: BolusEnactmentResult) in
                guard let self = self else { return }
                if !Self.keepsPendingRemoteBolus(after: result) {
                    self.clearPendingRemoteBolus(pending)
                }
                Task {
                    if result.isSuccess {
                        await self.logSuccess(
                            "Remote command processed successfully. \(payload.humanReadableDescription())",
                            payload: payload,
                            customNotificationMessage: "Bolus started"
                        )
                    } else {
                        await self.logError(
                            Self.remoteBolusFailureMessage(for: result, carbsStored: carbsStored),
                            payload: payload
                        )
                    }
                }
            }
    }

    /// The units the pump delivers for `requested`, rounded to the pump's supported bolus volume when a pump is set up.
    static func pendingBolusUnits(requested: Decimal, roundToSupportedVolume: ((Double) -> Double)?) -> Decimal {
        guard let roundToSupportedVolume = roundToSupportedVolume else { return requested }
        return NSNumber(value: roundToSupportedVolume(Double(truncating: requested as NSNumber))).decimalValue
    }

    static let uncertainDeliveryMessage = "Bolus may have been delivered. Check the history before sending another bolus."

    /// An enacted bolus, or one whose delivery is uncertain, stays pending until the dose history shows it.
    static func keepsPendingRemoteBolus(after result: BolusEnactmentResult) -> Bool {
        switch result {
        case .enacted,
             .uncertainDelivery:
            return true
        case .failed:
            return false
        }
    }

    /// The reply to the sender when the bolus was not confirmed by the pump.
    static func remoteBolusFailureMessage(for result: BolusEnactmentResult, carbsStored: Bool) -> String {
        switch result {
        case .uncertainDelivery:
            return carbsStored ? "Carbs were stored. " + uncertainDeliveryMessage : uncertainDeliveryMessage
        case let .failed(message, error):
            guard carbsStored else { return message }
            return "Carbs were stored, but the bolus failed: \(error?.localizedDescription ?? message)"
        case let .enacted(message):
            return message
        }
    }
}

private extension BolusSafetyRejection {
    func remoteCommandMessage(bolusAmount: Decimal) -> String {
        switch self {
        case let .exceedsMaxBolus(maxBolus):
            return "Command rejected: bolus amount (\(bolusAmount) units) exceeds the maximum allowed (\(maxBolus) units)."
        case .iobUnavailable:
            return "Command rejected: current IOB is not available."
        case let .exceedsMaxIOB(currentIOB, maxIOB):
            return "Command rejected: bolus amount (\(bolusAmount) units) would exceed max IOB (\(maxIOB) units). Current IOB: \(currentIOB.formattedIOB(locale: Locale(identifier: "en_US_POSIX"))) units."
        case .recentBolusWithinWindow:
            return "Command rejected: boluses totaling more than 20% of the requested amount have been delivered since the command was sent."
        }
    }
}
