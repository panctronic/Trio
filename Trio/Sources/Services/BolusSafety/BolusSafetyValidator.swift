import CoreData
import Foundation
import Swinject

/// Shared safety checks applied to any bolus command originating outside the main bolus UI
/// (remote notifications, Shortcuts, Apple Watch, etc.). Keeps validation logic consistent across call sites.
protocol BolusSafetyValidator {
    /// Max bolus, max IOB, and the recent-bolus 20% check over the last
    /// `BolusSafetyEvaluator.recentBolusWindowMinutes`.
    /// - Parameter overriding: checks the user has seen fail and chosen to bolus through. Only checks whose
    ///   `canBeOverridden` is true are skipped.
    func validate(bolusAmount: Decimal, overriding: Set<BolusSafetyCheck>) async throws -> BolusSafetyResult
    /// Max bolus and max IOB only, for callers that check recent treatments themselves. IOB includes boluses delivered
    /// since it was calculated, plus `unrecordedUnits`: boluses the caller knows of that may not be stored yet (in
    /// progress on the pump, or sent and not yet reported).
    func validateLimits(bolusAmount: Decimal, unrecordedUnits: Decimal) async throws -> BolusSafetyResult
    func fetchTotalRecentBolusAmount(since date: Date) async throws -> Decimal
}

extension BolusSafetyValidator {
    func validate(bolusAmount: Decimal) async throws -> BolusSafetyResult {
        try await validate(bolusAmount: bolusAmount, overriding: [])
    }
}

/// The individual checks `BolusSafetyEvaluator` runs. The raw values travel between the phone and the Watch.
enum BolusSafetyCheck: String, CaseIterable {
    case maxBolus = "max_bolus"
    case iobAvailable = "iob_available"
    case maxIOB = "max_iob"
    case recentBolus = "recent_bolus"

    /// Max bolus is a hard limit, as on the main bolus screen. The other checks only ask the user to confirm.
    var canBeOverridden: Bool {
        self != .maxBolus
    }

    /// How long a user's confirmation past a failed check stays valid. It matches the recent-bolus window, so the
    /// reason the user saw is at most about one loop cycle old.
    static let overrideLifetimeMinutes = BolusSafetyEvaluator.recentBolusWindowMinutes

    /// The checks a user confirmed to bolus through, or none if the confirmation has expired, so that every check
    /// runs again on current data.
    /// - Parameters:
    ///   - rawValues: The confirmed checks' raw values; unknown values are ignored
    ///   - issuedAt: When the user was asked to confirm, as seconds since 1970 on this device's clock
    static func overridden(_ rawValues: [String], issuedAt: TimeInterval?, now: Date = Date()) -> Set<BolusSafetyCheck> {
        guard let issuedAt,
              (0 ... TimeInterval(overrideLifetimeMinutes * 60)).contains(now.timeIntervalSince1970 - issuedAt)
        else { return [] }
        return Set(rawValues.compactMap(BolusSafetyCheck.init(rawValue:)))
    }
}

enum BolusSafetyResult: Equatable {
    case allowed
    case rejected(BolusSafetyRejection)
}

enum BolusSafetyRejection: Equatable {
    case exceedsMaxBolus(maxBolus: Decimal)
    /// IOB is missing, or older than `BolusSafetyEvaluator.maxIOBAge`.
    case iobUnavailable
    case exceedsMaxIOB(currentIOB: Decimal, maxIOB: Decimal)
    case recentBolusWithinWindow(totalRecent: Decimal)

    var check: BolusSafetyCheck {
        switch self {
        case .exceedsMaxBolus: return .maxBolus
        case .iobUnavailable: return .iobAvailable
        case .exceedsMaxIOB: return .maxIOB
        case .recentBolusWithinWindow: return .recentBolus
        }
    }
}

extension BolusSafetyRejection {
    /// User-facing explanation of the rejection, shown by Shortcuts and on the Watch.
    func localizedMessage(requestedAmount: Decimal) -> String {
        switch self {
        case let .exceedsMaxBolus(maxBolus):
            return String(
                localized:
                "The bolus cannot be larger than the pump setting max bolus (\(maxBolus.description))."
            )
        case .iobUnavailable:
            return String(
                localized:
                "Bolus blocked: current IOB is not available."
            )
        case let .exceedsMaxIOB(currentIOB, maxIOB):
            return String(
                localized:
                "Bolus blocked: a \(requestedAmount.formatted()) U bolus would exceed max IOB (\(maxIOB.formatted()) U). Current IOB: \(currentIOB.formattedIOB()) U."
            )
        case .recentBolusWithinWindow:
            return String(
                localized:
                "Bolus blocked: a significant bolus was delivered recently and may not be reflected in IOB yet.",
                comment: "Shortcut and Watch message when a bolus is blocked because a bolus delivered since the IOB was last calculated (or in the last few minutes) is at least 20% of the requested amount"
            )
        }
    }
}

struct BolusSafetyInputs: Equatable {
    let maxBolus: Decimal
    let maxIOB: Decimal
    let currentIOB: Decimal?
    /// Sum of bolus amounts delivered within the recent-bolus window (see `BolusSafetyEvaluator.recentBolusWindowMinutes`).
    let totalRecentBolus: Decimal
    /// When `currentIOB` is nil because the IOB is too old: that old IOB plus every bolus since it was calculated. An
    /// upper bound (old IOB has only decayed since), used for max IOB when the user confirmed past `.iobAvailable`.
    var staleIOBEstimate: Decimal? = nil
}

enum BolusSafetyEvaluator {
    static let recentBolusThreshold: Decimal = 0.2
    static let recentBolusWindowMinutes: Int = 6
    /// IOB older than this is treated as unknown. The loop refreshes it every five minutes, so an
    /// older value means the loop has not been running and boluses since then may be missing from it.
    static let maxIOBAge: TimeInterval = 10 * 60

    /// Start of the recent-bolus window. It reaches back to the time the IOB was calculated when that is earlier than
    /// the usual window: IOB may be up to `maxIOBAge` old, and a bolus delivered after it was calculated is in neither
    /// the IOB nor a shorter window, so it would be counted nowhere.
    static func recentBolusWindowStart(now: Date, iobDate: Date?) -> Date {
        let window = now.addingTimeInterval(-Double(recentBolusWindowMinutes * 60))
        guard let iobDate else { return window }
        return min(window, iobDate)
    }

    /// The IOB value to check against, or nil when it is missing or too old to be trusted.
    static func usableIOB(_ sample: (iob: Decimal, date: Date)?, now: Date = Date()) -> Decimal? {
        guard let sample else { return nil }
        guard now.timeIntervalSince(sample.date) <= maxIOBAge else { return nil }
        return sample.iob
    }

    static func evaluateLimits(
        bolusAmount: Decimal,
        maxBolus: Decimal,
        maxIOB: Decimal,
        currentIOB: Decimal?
    ) -> BolusSafetyResult {
        if bolusAmount > maxBolus {
            return .rejected(.exceedsMaxBolus(maxBolus: maxBolus))
        }
        guard let currentIOB = currentIOB else {
            return .rejected(.iobUnavailable)
        }
        if (currentIOB + bolusAmount) > maxIOB {
            return .rejected(.exceedsMaxIOB(currentIOB: currentIOB, maxIOB: maxIOB))
        }
        return .allowed
    }

    /// - Parameter overriding: checks to skip; those that cannot be overridden are run regardless.
    ///   With `.iobAvailable` overridden and IOB too old, max IOB is checked against `staleIOBEstimate`; only with no
    ///   IOB at all is it skipped.
    static func evaluate(
        bolusAmount: Decimal,
        inputs: BolusSafetyInputs,
        overriding: Set<BolusSafetyCheck> = []
    ) -> BolusSafetyResult {
        let skipped = overriding.filter(\.canBeOverridden)
        if bolusAmount > inputs.maxBolus {
            return .rejected(.exceedsMaxBolus(maxBolus: inputs.maxBolus))
        }
        if let currentIOB = inputs.currentIOB {
            if !skipped.contains(.maxIOB), (currentIOB + bolusAmount) > inputs.maxIOB {
                return .rejected(.exceedsMaxIOB(currentIOB: currentIOB, maxIOB: inputs.maxIOB))
            }
        } else if !skipped.contains(.iobAvailable) {
            return .rejected(.iobUnavailable)
        } else if let staleIOB = inputs.staleIOBEstimate, !skipped.contains(.maxIOB), (staleIOB + bolusAmount) > inputs.maxIOB {
            return .rejected(.exceedsMaxIOB(currentIOB: staleIOB, maxIOB: inputs.maxIOB))
        }
        if !skipped.contains(.recentBolus), inputs.totalRecentBolus >= bolusAmount * recentBolusThreshold {
            return .rejected(.recentBolusWithinWindow(totalRecent: inputs.totalRecentBolus))
        }
        return .allowed
    }
}

final class BaseBolusSafetyValidator: BolusSafetyValidator, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var iobService: IOBService!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    /// The latest IOB plus every bolus delivered after it was calculated (and `unrecordedUnits`), split into a usable
    /// value when the IOB is fresh enough, and an estimate when it is too old (see `BolusSafetyInputs.staleIOBEstimate`).
    private func iobEstimate(unrecordedUnits: Decimal = 0) async throws
        -> (current: Decimal?, stale: Decimal?, sampleDate: Date?)
    {
        guard let sample = iobService.currentIOBSample else { return (nil, nil, nil) }
        let estimate = sample.iob + (try await fetchTotalRecentBolusAmount(since: sample.date)) + unrecordedUnits
        guard BolusSafetyEvaluator.usableIOB(sample) != nil else {
            warning(
                .bolus,
                "Bolus check: IOB is \(Int(Date().timeIntervalSince(sample.date) / 60)) min old, treating it as unavailable"
            )
            return (nil, estimate, sample.date)
        }
        return (estimate, nil, sample.date)
    }

    func validateLimits(bolusAmount: Decimal, unrecordedUnits: Decimal) async throws -> BolusSafetyResult {
        BolusSafetyEvaluator.evaluateLimits(
            bolusAmount: bolusAmount,
            maxBolus: settingsManager.pumpSettings.maxBolus,
            maxIOB: settingsManager.preferences.maxIOB,
            currentIOB: try await iobEstimate(unrecordedUnits: unrecordedUnits).current
        )
    }

    func validate(bolusAmount: Decimal, overriding: Set<BolusSafetyCheck>) async throws -> BolusSafetyResult {
        let iob = try await iobEstimate()
        let windowStart = BolusSafetyEvaluator.recentBolusWindowStart(now: Date(), iobDate: iob.current == nil ? nil : iob.sampleDate)
        let inputs = BolusSafetyInputs(
            maxBolus: settingsManager.pumpSettings.maxBolus,
            maxIOB: settingsManager.preferences.maxIOB,
            currentIOB: iob.current,
            totalRecentBolus: try await fetchTotalRecentBolusAmount(since: windowStart),
            staleIOBEstimate: iob.stale
        )
        return BolusSafetyEvaluator.evaluate(bolusAmount: bolusAmount, inputs: inputs, overriding: overriding)
    }

    func fetchTotalRecentBolusAmount(since date: Date) async throws -> Decimal {
        let fetchContext = CoreDataStack.shared.newTaskContext()
        fetchContext.name = "fetchTotalRecentBolusAmount"
        let predicate = NSPredicate(
            format: "type == %@ AND timestamp > %@",
            PumpEventStored.EventType.bolus.rawValue,
            date as NSDate
        )
        return try await CoreDataStack.shared.fetchDictionaries(
            ofType: PumpEventStored.self,
            onContext: fetchContext,
            predicate: predicate,
            key: "timestamp",
            ascending: true,
            fetchLimit: nil,
            propertiesToFetch: ["bolus.amount"]
        ) { bolusDictionaries in
            bolusDictionaries.compactMap { ($0["bolus.amount"] as? NSNumber)?.decimalValue }.reduce(0, +)
        }
    }
}
