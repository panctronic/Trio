import Foundation

/// VoiceOver wording for the Live Activity, the Dynamic Island and the Watch Smart Stack.
///
/// Built from the content state alone, so it compiles into both the app (where it is unit tested) and the widget
/// extension. The views otherwise show glucose as a bare number, an arrow glyph and a colour, none of which VoiceOver
/// can read in a useful way.
///
/// The update time is spoken as a clock time ("updated at 10:35"), not as "5 minutes ago": a Live Activity is
/// rendered once per update, so a relative age baked into the label would keep saying "1 minute ago" for as long as
/// updates stop arriving. When the system marks the activity stale, the label says so instead.
extension LiveActivityAttributes.ContentState {
    /// Spoken trend for the arrow glyphs in `direction` ("↑↑", "↗︎", "→" ...), or nil when there is no usable trend.
    static func spokenTrend(forArrow arrow: String?) -> String? {
        guard let arrow else { return nil }
        // the symbols carry a text-presentation variation selector ("↗︎"); compare the bare arrows
        let bare = String(String.UnicodeScalarView(arrow.unicodeScalars.filter { !(0xFE00 ... 0xFE0F).contains($0.value) }))
        switch bare {
        case "↑↑↑",
             "↑↑":
            return String(localized: "rising quickly", comment: "Accessibility: glucose trend")
        case "↑":
            return String(localized: "rising", comment: "Accessibility: glucose trend")
        case "↗":
            return String(localized: "rising slowly", comment: "Accessibility: glucose trend")
        case "→":
            return String(localized: "steady", comment: "Accessibility: glucose trend")
        case "↘":
            return String(localized: "falling slowly", comment: "Accessibility: glucose trend")
        case "↓":
            return String(localized: "falling", comment: "Accessibility: glucose trend")
        case "↓↓",
             "↓↓↓":
            return String(localized: "falling quickly", comment: "Accessibility: glucose trend")
        default:
            return nil
        }
    }

    /// "Glucose 120 milligrams per deciliter, rising, delta +3", or "..., outdated" when the system marked it stale.
    func glucoseAccessibilityLabel(isStale: Bool) -> String {
        guard !isInitialState else {
            return String(localized: "Live Activity Expired. Open Trio to Refresh")
        }
        guard !bg.isEmpty, bg != "--" else {
            return String(localized: "Glucose unavailable", comment: "Accessibility: no fresh glucose")
        }
        var parts = [String(localized: "Glucose", comment: "Accessibility: glucose label") + " \(bg) " + spokenUnit]
        if isStale {
            parts.append(String(localized: "outdated", comment: "Accessibility: a glucose reading that is no longer current"))
        } else {
            if let trend = Self.spokenTrend(forArrow: direction) {
                parts.append(trend)
            }
            if !change.isEmpty {
                parts.append(String(localized: "delta", comment: "Accessibility: glucose delta") + " \(change)")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// "milligrams per deciliter" / "millimoles per liter", so VoiceOver doesn't spell out "mg/dL".
    var spokenUnit: String {
        let per = " " + String(localized: "per", comment: "Accessibility: unit separator, as in grams per unit") + " "
        switch unit {
        case "mg/dL":
            return String(localized: "milligrams", comment: "Accessibility: spoken unit") + per
                + String(localized: "deciliter", comment: "Accessibility: spoken unit")
        case "mmol/L":
            return String(localized: "millimoles", comment: "Accessibility: spoken unit") + per
                + String(localized: "liter", comment: "Accessibility: spoken unit")
        default:
            return unit
        }
    }

    /// "updated at 10:35", or nil before the first loop has run.
    func updatedAccessibilityLabel(timeStyle: Date.FormatStyle.TimeStyle = .shortened) -> String? {
        guard let date else { return nil }
        let time = date.formatted(date: .omitted, time: timeStyle)
        return String(localized: "updated at \(time)", comment: "Accessibility: Live Activity update time; %@ is a clock time")
    }

    /// Spoken insulin on board, e.g. "Insulin on board 1.5 units".
    var iobAccessibilityLabel: String {
        String(localized: "Insulin on board") + " "
            + detailedViewState.iob.formatted(.number.precision(.fractionLength(0 ... 1))) + " "
            + String(localized: "units", comment: "Accessibility: spoken unit")
    }

    /// Spoken carbs on board, e.g. "Carbs on board 20 grams".
    var cobAccessibilityLabel: String {
        String(localized: "Carbs on board") + " "
            + detailedViewState.cob.formatted(.number.precision(.fractionLength(0))) + " "
            + String(localized: "grams", comment: "Grams unit")
    }

    /// One summary for the whole activity: glucose, trend, change, IOB / COB where the layout shows them, and the
    /// update time.
    func accessibilitySummary(isStale: Bool, includesIOB: Bool = false, includesCOB: Bool = false) -> String {
        var parts = [glucoseAccessibilityLabel(isStale: isStale)]
        guard !isInitialState else { return parts[0] }
        if includesIOB { parts.append(iobAccessibilityLabel) }
        if includesCOB { parts.append(cobAccessibilityLabel) }
        if let updated = updatedAccessibilityLabel() { parts.append(updated) }
        return parts.joined(separator: ", ")
    }

    /// "delta +3", or nil when there is no change to speak
    func deltaAccessibilityLabel(isStale: Bool) -> String? {
        guard !isStale, !change.isEmpty else { return nil }
        return String(localized: "delta", comment: "Accessibility: glucose delta") + " \(change)"
    }
}
