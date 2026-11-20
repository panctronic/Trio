import CoreData
import Foundation

extension NSPredicate {
    static var allOverridePresets: NSPredicate {
        NSPredicate(format: "isPreset == %@", true as NSNumber)
    }

    static var lastActiveOverride: NSPredicate {
        // For non-indefinite overrides, we still want to filter by date
        // For indefinite overrides, we want them regardless of date
        NSPredicate(
            format: "(date >= %@ OR indefinite == %@) AND enabled == %@",
            Date.oneDayAgo as NSDate,
            true as NSNumber,
            true as NSNumber
        )
    }
}

extension NSPredicate {
    /// Enabled overrides that can run out: everything with a duration, whatever its start date.
    /// `lastActiveOverride` stops matching a finite override a day after it started, so it cannot
    /// be used to find every override that still needs ending.
    static var enabledFiniteOverrides: NSPredicate {
        NSPredicate(format: "enabled == %@ AND indefinite == %@", true as NSNumber, false as NSNumber)
    }
}

extension OverrideStored {
    /// When a finite override runs out: its start plus its duration. A finite override without a
    /// positive duration ran out when it started, which is what the Home screen has always shown.
    /// `nil` for an indefinite override, or for one without a start date.
    var expiryDate: Date? {
        guard !indefinite, let date else { return nil }
        let minutes = max(duration?.doubleValue ?? 0, 0)
        return date.addingTimeInterval(minutes * 60)
    }

    /// Whether this override's duration has run out at `now`, regardless of whether anything has
    /// ended it in the store yet. Indefinite overrides never run out.
    func hasExpired(at now: Date) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate <= now
    }
}

extension OverrideStored {
    static func fetch(_ predicate: NSPredicate, ascending: Bool, fetchLimit: Int? = nil) -> NSFetchRequest<OverrideStored> {
        let request = OverrideStored.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: ascending)]
        request.predicate = predicate
        if let fetchLimit = fetchLimit {
            request.fetchLimit = fetchLimit
        }
        return request
    }
}

extension OverrideStored {
    enum EventType: String, JSON {
        case nsExercise = "Exercise"
    }
}
