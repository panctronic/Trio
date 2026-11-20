import CoreData
import Foundation

extension NSPredicate {
    static var lastActiveAdjustmentNotYetUploadedToNightscout: NSPredicate {
        let date = Date.nightscoutUploadWindowStart
        return NSPredicate(
            format: "date >= %@ AND enabled == %@ AND isUploadedToNS == %@",
            date as NSDate,
            true as NSNumber,
            false as NSNumber
        )
    }

    /// Finished override and temp target runs (OverrideRunStored, TempTargetRunStored) that have not
    /// reached Nightscout yet. The window applies to `endDate`.
    static var adjustmentRunsNotYetUploadedToNightscout: NSPredicate {
        NSPredicate(
            format: "endDate >= %@ AND isUploadedToNS == %@",
            Date.nightscoutUploadWindowStart as NSDate,
            false as NSNumber
        )
    }
}
