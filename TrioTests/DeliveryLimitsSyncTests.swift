import Foundation
import LoopKit
import Testing

@testable import Trio

/// Pins the `PumpSettings` -> `DeliveryLimits` mapping (`PumpSettings.deliveryLimits`)
/// that `BaseDeviceDataManager.pumpManager.didSet` and the settings providers
/// (units & limits, algorithm advanced settings, Nightscout import) pass to
/// `PumpManager.syncDeliveryLimits`. A regression that collapses the user's
/// limits to the `PumpInitialSettings` defaults, or swaps units, breaks here.
@Suite("Delivery Limits Sync Tests") struct DeliveryLimitsSyncTests {
    private let basalUnit = LoopUnit.internationalUnitsPerHour
    private let bolusUnit = LoopUnit.internationalUnit

    private func makeSettings(maxBasal: Decimal, maxBolus: Decimal) -> PumpSettings {
        PumpSettings(insulinActionCurve: 6, maxBolus: maxBolus, maxBasal: maxBasal)
    }

    @Test("maxBasal maps to maximumBasalRate in U/hr") func testMaxBasalMapping() {
        let limits = makeSettings(maxBasal: 5.0, maxBolus: 10.0).deliveryLimits

        #expect(limits.maximumBasalRate?.doubleValue(for: basalUnit) == 5.0)
    }

    @Test("maxBolus maps to maximumBolus in U") func testMaxBolusMapping() {
        let limits = makeSettings(maxBasal: 5.0, maxBolus: 10.0).deliveryLimits

        #expect(limits.maximumBolus?.doubleValue(for: bolusUnit) == 10.0)
    }

    @Test("Fractional limits survive the Decimal -> Double conversion") func testFractionalLimits() throws {
        // Settings are decoded from JSON, so build the Decimals from strings as the decoder would.
        let limits = makeSettings(maxBasal: Decimal(string: "0.35")!, maxBolus: Decimal(string: "2.25")!).deliveryLimits

        let basal = try #require(limits.maximumBasalRate?.doubleValue(for: basalUnit))
        let bolus = try #require(limits.maximumBolus?.doubleValue(for: bolusUnit))
        #expect(abs(basal - 0.35) < 1E-9)
        #expect(abs(bolus - 2.25) < 1E-9)
    }

    /// The derived limit must be the user's configured value, not the `PumpInitialSettings` default.
    @Test("User-configured limit is preserved, not collapsed to the 2 U/hr default") func testDoesNotFallBackToDefault() {
        let configuredMaxBasal: Decimal = 3.0
        let defaultMaxBasal = PumpConfig.PumpInitialSettings.default.maxBasalRateUnitsPerHour

        let limits = makeSettings(maxBasal: configuredMaxBasal, maxBolus: 10.0).deliveryLimits

        #expect(limits.maximumBasalRate?.doubleValue(for: basalUnit) == Double(configuredMaxBasal))
        #expect(limits.maximumBasalRate?.doubleValue(for: basalUnit) != defaultMaxBasal)
    }

    /// The derived limit must be the user's configured value, not the `PumpInitialSettings` default.
    @Test("User-configured bolus limit is preserved, not collapsed to the default") func testBolusDoesNotFallBackToDefault() {
        let configuredMaxBolus: Decimal = 25.0
        let defaultMaxBolus = PumpConfig.PumpInitialSettings.default.maxBolusUnits

        let limits = makeSettings(maxBasal: 3.0, maxBolus: configuredMaxBolus).deliveryLimits

        #expect(limits.maximumBolus?.doubleValue(for: bolusUnit) == Double(configuredMaxBolus))
        #expect(limits.maximumBolus?.doubleValue(for: bolusUnit) != defaultMaxBolus)
    }
}
