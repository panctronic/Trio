import CoreData
import Foundation

extension Date {
    static var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    static var oneDayAgoInMinutes: Date {
        Calendar.current.date(byAdding: .minute, value: -1440, to: Date())!
    }

    static var oneDayAgo: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    }

    static var oneHourAgo: Date {
        Calendar.current.date(byAdding: .minute, value: -60, to: Date())!
    }

    static var halfHourAgo: Date {
        Calendar.current.date(byAdding: .minute, value: -30, to: Date())!
    }

    static var twentyMinutesAgo: Date {
        Calendar.current.date(byAdding: .minute, value: -20, to: Date())!
    }

    static var twoHoursAgo: Date {
        Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
    }

    static var fourHoursAgo: Date {
        Calendar.current.date(byAdding: .hour, value: -4, to: Date())!
    }

    static var sixHoursAgo: Date {
        Calendar.current.date(byAdding: .hour, value: -6, to: Date())!
    }

    static var oneWeekAgo: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    }

    static var oneMonthAgo: Date {
        Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    }

    static var threeMonthsAgo: Date {
        Calendar.current.date(byAdding: .month, value: -3, to: Date())!
    }

    /// Oldest record the Nightscout upload passes still pick up.
    static var nightscoutUploadWindowStart: Date {
        Calendar.current.date(byAdding: .day, value: -UploadBacklog.nightscoutDays, to: Date())!
    }

    /// Oldest record the Apple Health upload passes still pick up.
    static var appleHealthUploadWindowStart: Date {
        Calendar.current.date(byAdding: .day, value: -UploadBacklog.appleHealthDays, to: Date())!
    }

    /// Oldest record the Tidepool upload passes still pick up.
    static var tidepoolUploadWindowStart: Date {
        Calendar.current.date(byAdding: .day, value: -UploadBacklog.tidepoolDays, to: Date())!
    }
}

/// How far back the "not yet uploaded" queries look, and how much one upload pass takes.
///
/// A record that could not be uploaded (phone offline, server outage, expired Tidepool login) is
/// retried on every pass until it falls out of its window. All windows are shorter than the
/// 90-day Core Data retention.
///
/// Passes fetch at most `maxRowsPerPass` rows (`maxPumpEventsPerPass` for the Apple Health and
/// Tidepool insulin uploads, whose payload can double with temp basal adjustments): the last day
/// newest first, then the backlog oldest first (`CoreDataStack.fetchUploadBatchAndMap`). Marking a batch as uploaded changes the result of the upload controllers'
/// fetch, which requests the next pass, so a backlog drains in bounded steps.
enum UploadBacklog {
    static let defaultNightscoutDays = 7
    static let defaultAppleHealthDays = 30
    static let defaultTidepoolDays = 30
    static let minDays = 1
    static let maxDays = 90

    static let nightscoutDaysKey = "UploadBacklog.nightscoutDays"
    static let appleHealthDaysKey = "UploadBacklog.appleHealthDays"
    static let tidepoolDaysKey = "UploadBacklog.tidepoolDays"

    /// Nightscout accepts back-dated entries and treatments; default 7 days covers a long outage.
    static var nightscoutDays: Int {
        get { storedDays(forKey: nightscoutDaysKey, defaultValue: defaultNightscoutDays) }
        set { UserDefaults.standard.set(clampedDays(newValue), forKey: nightscoutDaysKey) }
    }

    /// Apple Health is written locally; default 30 days covers long stretches without permission or
    /// with the device locked.
    static var appleHealthDays: Int {
        get { storedDays(forKey: appleHealthDaysKey, defaultValue: defaultAppleHealthDays) }
        set { UserDefaults.standard.set(clampedDays(newValue), forKey: appleHealthDaysKey) }
    }

    /// A Tidepool login can stay expired for weeks before anyone notices; default 30 days.
    static var tidepoolDays: Int {
        get { storedDays(forKey: tidepoolDaysKey, defaultValue: defaultTidepoolDays) }
        set { UserDefaults.standard.set(clampedDays(newValue), forKey: tidepoolDaysKey) }
    }

    private static func storedDays(forKey key: String, defaultValue: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return clampedDays(UserDefaults.standard.integer(forKey: key))
    }

    private static func clampedDays(_ value: Int) -> Int {
        min(max(value, minDays), maxDays)
    }

    static let maxRowsPerPass = 1000
    static let maxPumpEventsPerPass = 500
}

extension NSPredicate {
    static let all = NSPredicate(format: "TRUEPREDICATE")

    static let none = NSPredicate(format: "FALSEPREDICATE")

    /// GlucoseStored rows from a sensor, excluding manual entries.
    static let cgmGlucose = NSPredicate(format: "isManual == NO")

    /// How far ahead of the phone clock a glucose reading may be dated and still count
    /// as current. Absorbs small clock differences between the phone and a CGM source.
    static let glucoseFutureTolerance: TimeInterval = 60

    /// GlucoseStored rows dated no later than now + `glucoseFutureTolerance`. A reading
    /// dated in the future (wrong clock on the source) must not become the "latest"
    /// reading for sync dates, the algorithm or glucose alarms.
    static var glucoseNotInFuture: NSPredicate {
        glucoseNotInFuture(now: Date())
    }

    static func glucoseNotInFuture(now: Date) -> NSPredicate {
        NSPredicate(format: "date <= %@", now.addingTimeInterval(glucoseFutureTolerance) as NSDate)
    }

    static var predicateForOneDayAgoInMinutes: NSPredicate {
        let date = Date.oneDayAgoInMinutes
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var predicateForOneDayAgo: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    /// For entities keyed on `startDate` (OverrideRunStored, TempTargetRunStored).
    static var predicateForStartDateOneDayAgo: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "startDate >= %@", date as NSDate)
    }

    static func predicateForStartDate(since date: Date) -> NSPredicate {
        NSPredicate(format: "startDate >= %@", date as NSDate)
    }

    static var carbsHistory: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "date >= %@ AND carbs > 0", date as NSDate)
    }

    static var predicateForOneHourAgo: NSPredicate {
        let date = Date.oneHourAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var predicateFor30MinAgo: NSPredicate {
        let date = Date.halfHourAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var predicateFor20MinAgo: NSPredicate {
        let date = Date.twentyMinutesAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var predicateFor30MinAgoForDetermination: NSPredicate {
        let date = Date.halfHourAgo
        return NSPredicate(format: "deliverAt >= %@", date as NSDate)
    }

    static var predicateFor120MinAgo: NSPredicate {
        let date = Date.twoHoursAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var predicateForFourHoursAgo: NSPredicate {
        let date = Date.fourHoursAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static var predicateForSixHoursAgo: NSPredicate {
        let date = Date.sixHoursAgo
        return NSPredicate(format: "date >= %@", date as NSDate)
    }

    static func predicateForDateBetween(start: Date, end: Date) -> NSPredicate {
        NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate)
    }

    static func predicateForDeliverAtBetween(start: Date, end: Date) -> NSPredicate {
        NSPredicate(format: "deliverAt >= %@ AND deliverAt <= %@", start as NSDate, end as NSDate)
    }

    static func predicateForTimestampBetween(start: Date, end: Date) -> NSPredicate {
        NSPredicate(format: "timestamp >= %@ AND timestamp <= %@", start as NSDate, end as NSDate)
    }
}
