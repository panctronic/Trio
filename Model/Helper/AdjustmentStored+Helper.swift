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
}
