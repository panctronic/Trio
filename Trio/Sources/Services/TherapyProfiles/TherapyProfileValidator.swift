import Foundation
import LoopKit

/// The therapy editors' value ranges, glucose in mg/dL.
enum TherapyProfileLimits {
    struct Range {
        let min: Decimal
        let max: Decimal
        let step: Decimal
    }

    static let carbRatio = Range(min: 1, max: 50, step: 0.1)
    static let sensitivity = Range(min: 9, max: 540, step: 1)
    static let target = Range(min: 72, max: 180, step: 1)
    static let maxSegments = 48
    static let segmentSeconds = 1800
    static let maxNameLength = 32
    /// The most profiles, Default included. Nightscout refuses a profile document much larger than this allows.
    static let maxProfiles = 20
}

struct TherapyBasalLimits: Equatable, Sendable {
    /// Nonzero rates the pump accepts.
    let supportedRates: [Decimal]
    let maxBasal: Decimal

    /// Supported rates up to max basal, ascending.
    var allowedRates: [Decimal] {
        supportedRates.filter { $0 > 0 && $0 <= maxBasal + Self.tolerance }.sorted()
    }

    static let tolerance: Decimal = 0.000001

    /// The basal editor's rates when no pump is connected.
    static let fallbackRates: [Decimal] = stride(from: 5.0, to: 1001.0, by: 5.0).map { ($0.decimal ?? .zero) / 100 }

    static let editorLimits = TherapyBasalLimits(supportedRates: fallbackRates, maxBasal: fallbackRates.last ?? 0)
}

extension TherapyBasalLimits {
    /// The pump's nonzero rates, or the basal editor's rates without a pump.
    init(pumpManager: PumpManager?, maxBasal: Decimal) {
        let rates = pumpManager?.supportedBasalRates.filter { $0 > 0 }.map { Decimal($0).rounded(scale: 3) }
        self.init(supportedRates: rates ?? Self.fallbackRates, maxBasal: maxBasal)
    }
}

enum TherapyProfileValidator {
    /// `existingNames` are the other profiles' names.
    static func validateName(_ rawName: String, existingNames: [String], isDefaultProfile: Bool = false) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != rawName {
            return String(localized: "The name must not start or end with spaces.")
        }
        if name.isEmpty {
            return String(localized: "The name must not be empty.")
        }
        if name.count > TherapyProfileLimits.maxNameLength {
            return String(localized: "The name must be at most \(TherapyProfileLimits.maxNameLength) characters.")
        }
        if name.contains(".") {
            return String(localized: "The name must not contain a period.")
        }
        if name.hasPrefix("$") {
            return String(localized: "The name must not start with $.")
        }
        if !isDefaultProfile, name.caseInsensitiveCompare(TrioTherapyProfile.defaultName) == .orderedSame {
            return String(localized: "The name \(TrioTherapyProfile.defaultName) is reserved.")
        }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return String(localized: "A profile named \(name) already exists.")
        }
        return nil
    }

    /// The reason the profile is not acceptable, or nil.
    static func validate(_ profile: TrioTherapyProfile, basalLimits: TherapyBasalLimits) -> String? {
        problems(profile, basalLimits: basalLimits).first
    }

    /// The first problem `proposed` has that `current` does not have, or nil. Used for edits of the live settings:
    /// an edit must not introduce a problem, but a problem the live values already have must not block it, or the user
    /// could fix neither that schedule nor another one.
    ///
    /// Problems are compared per check, not by message: a schedule's shape problem counts as existing when `current`'s
    /// schedule has the same one, and a value counts as existing when `current` already has that same offending value in
    /// that schedule, wherever it starts. So an edit may fix some of several bad entries, or move one, but not add a value
    /// that `current` did not already have wrong.
    static func validateEdit(
        from current: TrioTherapyProfile,
        to proposed: TrioTherapyProfile,
        basalLimits: TherapyBasalLimits
    ) -> String? {
        let currentSections = sections(current, basalLimits: basalLimits)
        for (index, section) in sections(proposed, basalLimits: basalLimits).enumerated() {
            let before = currentSections[index]
            if let reason = validateSchedule(section.starts, label: section.label),
               reason != validateSchedule(before.starts, label: before.label)
            {
                return reason
            }
            let existingBadValues = Set(before.entries.filter { section.problem($0) != nil }.map(\.value))
            for entry in section.entries where !existingBadValues.contains(entry.value) {
                if let reason = section.problem(entry) {
                    return reason
                }
            }
        }
        return nil
    }

    /// A schedule with its value check, in the order `problems` checks them.
    private struct Section {
        let label: String
        let starts: [Int]
        let entries: [TherapyScheduleEntry]
        let problem: (TherapyScheduleEntry) -> String?
    }

    private static func sections(_ profile: TrioTherapyProfile, basalLimits: TherapyBasalLimits) -> [Section] {
        let targets = profile.target.map { TherapyScheduleEntry(seconds: $0.seconds, value: $0.low) }
        return [
            Section(label: String(localized: "Basal Rates"), starts: profile.basal.map(\.seconds), entries: profile.basal) {
                basalRateProblem($0, basalLimits: basalLimits)
            },
            Section(label: String(localized: "Carb Ratios"), starts: profile.carbRatio.map(\.seconds), entries: profile.carbRatio) {
                valueProblem($0, range: TherapyProfileLimits.carbRatio, label: String(localized: "Carb Ratio"))
            },
            Section(
                label: String(localized: "Insulin Sensitivities"),
                starts: profile.sensitivity.map(\.seconds),
                entries: profile.sensitivity
            ) {
                valueProblem($0, range: TherapyProfileLimits.sensitivity, label: String(localized: "ISF"))
            },
            Section(label: String(localized: "Glucose Targets"), starts: profile.target.map(\.seconds), entries: targets) {
                valueProblem($0, range: TherapyProfileLimits.target, label: String(localized: "Target"))
            }
        ]
    }

    /// Every reason the profile is not acceptable, at most one per check, in the order `validate` reports them:
    /// the shape of each schedule first, then the values of each.
    static func problems(_ profile: TrioTherapyProfile, basalLimits: TherapyBasalLimits) -> [String] {
        let sections = sections(profile, basalLimits: basalLimits)
        let shapeProblems = sections.compactMap { validateSchedule($0.starts, label: $0.label) }
        let valueProblems = sections.compactMap { section in section.entries.lazy.compactMap(section.problem).first }
        return shapeProblems + valueProblems
    }

    private static func basalRateProblem(_ entry: TherapyScheduleEntry, basalLimits: TherapyBasalLimits) -> String? {
        let time = timeString(entry.seconds)
        let rate = entry.value.formatted()
        if entry.value <= 0 {
            return String(localized: "Basal rate at \(time) must be greater than 0 U/hr.")
        }
        if entry.value > basalLimits.maxBasal + TherapyBasalLimits.tolerance {
            return String(
                localized: "Basal rate \(rate) U/hr at \(time) exceeds the max basal rate of \(basalLimits.maxBasal.formatted()) U/hr."
            )
        }
        if !basalLimits.allowedRates.contains(where: { abs($0 - entry.value) <= TherapyBasalLimits.tolerance }) {
            return String(localized: "Basal rate \(rate) U/hr at \(time) is not supported by the pump.")
        }
        return nil
    }

    static func validateSchedule(_ starts: [Int], label: String) -> String? {
        guard let first = starts.first else {
            return String(localized: "\(label): the schedule is empty.")
        }
        if first != 0 {
            return String(localized: "\(label): the schedule must start at midnight.")
        }
        if starts.count > TherapyProfileLimits.maxSegments {
            return String(localized: "\(label): the schedule has more than \(TherapyProfileLimits.maxSegments) entries.")
        }
        for (index, start) in starts.enumerated() {
            if start < 0 || start >= 86400 || start % TherapyProfileLimits.segmentSeconds != 0 {
                return String(localized: "\(label): start times must be on the hour or half hour.")
            }
            if index > 0, start <= starts[index - 1] {
                return String(localized: "\(label): start times must be in ascending order.")
            }
        }
        return nil
    }

    /// The reason the list of scheduled switches is not acceptable, or nil. Profile names are checked by the caller.
    static func validateScheduledSwitches(_ entries: [ScheduledProfileSwitch]) -> String? {
        if entries.count > ScheduledProfileSwitch.maxCount {
            return String(localized: "There can be at most \(ScheduledProfileSwitch.maxCount) scheduled switches.")
        }
        if Set(entries.map(\.id)).count != entries.count || entries.contains(where: \.id.isEmpty) {
            return String(localized: "Each scheduled switch needs its own id.")
        }
        var slots: Set<Int> = []
        for entry in entries {
            guard (1 ... 7).contains(entry.weekday) else {
                return String(localized: "The weekday of a scheduled switch must be 1 to 7.")
            }
            guard (0 ..< 86400).contains(entry.time), entry.time % 60 == 0 else {
                return String(localized: "The time of a scheduled switch must be a whole minute of the day.")
            }
            guard slots.insert(entry.weekday * 86400 + entry.time).inserted else {
                return String(
                    localized: "Two scheduled switches start on \(weekdayName(entry.weekday)) at \(timeString(entry.time))."
                )
            }
        }
        return nil
    }

    /// The weekday's name, Sunday = 1.
    static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : String(weekday)
    }

    /// A schedule start time in the user's time format, the same on every day.
    static func timeString(_ seconds: Int) -> String {
        Date(timeIntervalSinceReferenceDate: TimeInterval(seconds))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .gmt))
    }

    private static func valueProblem(
        _ entry: TherapyScheduleEntry,
        range: TherapyProfileLimits.Range,
        label: String
    ) -> String? {
        let time = timeString(entry.seconds)
        let value = entry.value.formatted()
        if entry.value < range.min || entry.value > range.max {
            return String(
                localized: "\(label) \(value) at \(time) is outside \(range.min.formatted())–\(range.max.formatted())."
            )
        }
        if !isMultiple(entry.value - range.min, of: range.step) {
            return String(localized: "\(label) \(value) at \(time) is not a multiple of \(range.step.formatted()).")
        }
        return nil
    }

    static func isMultiple(_ value: Decimal, of step: Decimal) -> Bool {
        let quotient = NSDecimalNumber(decimal: value / step)
        let rounded = quotient.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        ))
        return abs(quotient.subtracting(rounded).decimalValue) < 0.000001
    }
}
