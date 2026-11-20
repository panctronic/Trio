import Foundation
import LoopKit

// Kept out of PumpSettings.swift because that file is also compiled by
// AlgorithmPackage, which does not depend on LoopKit.
extension PumpSettings {
    /// The user's configured max basal rate (U/hr) and max bolus (U) as the
    /// `DeliveryLimits` synced to the active pump manager.
    var deliveryLimits: DeliveryLimits {
        DeliveryLimits(
            maximumBasalRate: LoopQuantity(unit: .internationalUnitsPerHour, doubleValue: Double(maxBasal)),
            maximumBolus: LoopQuantity(unit: .internationalUnit, doubleValue: Double(maxBolus))
        )
    }
}
