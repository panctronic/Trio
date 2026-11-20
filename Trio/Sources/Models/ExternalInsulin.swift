import Foundation

/// Rules shared by every place external insulin (insulin taken outside the pump) is logged.
enum ExternalInsulin {
    /// Rounds to the nearest multiple of `increment`, without a cap.
    ///
    /// Pump rounding (`roundToSupportedBolusVolume`) also caps at the pump's largest bolus volume, which logged
    /// e.g. 40 U taken by pen as 30 U and under-reported IOB. Rounding to the nearest step, not down, keeps the
    /// logged amount as close as possible to what was taken. An amount below half a step rounds to 0 and must be
    /// refused (`nothingToLogMessage`), not logged.
    static func rounded(_ amount: Decimal, toIncrement increment: Decimal) -> Decimal {
        guard amount > 0 else { return 0 }
        guard increment > 0 else { return amount }
        var steps = amount / increment
        var wholeSteps = Decimal()
        NSDecimalRound(&wholeSteps, &steps, 0, .plain)
        return wholeSteps * increment
    }

    /// Shown instead of logging when the amount rounds to 0 U.
    static func nothingToLogMessage(increment: Decimal) -> String {
        String(
            localized: "Nothing logged: the amount rounds to 0 U. The smallest amount that can be logged is \(increment.formatted()) U.",
            comment: "Message when external insulin rounds to 0 U; the argument is the bolus increment"
        )
    }

    /// External insulin above max bolus is allowed but unusual, so it is always confirmed explicitly.
    static func needsExplicitConfirmation(_ amount: Decimal, maxBolus: Decimal) -> Bool {
        amount > maxBolus
    }

    /// The insulin was logged and only the forecast update failed. Saying so keeps the user from logging it again.
    static func loggedButForecastFailedMessage(amount: Decimal, error: Error) -> String {
        String(
            localized: "\(amount.formatted()) U of external insulin was logged. Do not log it again. Only updating the forecast failed: \(error.localizedDescription)",
            comment: "Message when external insulin was saved but the following determination failed; the arguments are the amount and the reason"
        )
    }
}
