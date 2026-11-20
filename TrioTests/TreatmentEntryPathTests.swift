import CoreData
import Foundation
import Testing

@testable import Trio

/// Checks for the ways treatments are entered outside the main bolus flow: Watch, Shortcuts, Treatments, History.
@Suite("Treatment Entry Path Tests", .serialized) struct TreatmentEntryPathTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Watch carbs

    @Test("Watch carbs within max carbs are accepted") func testWatchCarbsAccepted() {
        #expect(BaseWatchManager.watchCarbsRejection(carbs: 45, maxCarbs: 250) == nil)
        #expect(BaseWatchManager.watchCarbsRejection(carbs: 250, maxCarbs: 250) == nil)
    }

    @Test("Watch carbs above max carbs or not above 0 are refused") func testWatchCarbsRefused() {
        #expect(BaseWatchManager.watchCarbsRejection(carbs: 251, maxCarbs: 250) != nil)
        #expect(BaseWatchManager.watchCarbsRejection(carbs: 0, maxCarbs: 250) != nil)
        #expect(BaseWatchManager.watchCarbsRejection(carbs: -5, maxCarbs: 250) != nil)
    }

    @Test("Watch carbs are stored as a plain local carb entry") func testWatchCarbsEntry() {
        let entry = BaseWatchManager.watchCarbsEntry(carbs: 30, date: now)
        #expect(entry.carbs == 30)
        #expect(entry.actualDate == now)
        #expect(entry.fat == 0 && entry.protein == 0)
        #expect(entry.isFPU == false)
        #expect(entry.fpuID == nil)
        #expect(entry.enteredBy == CarbsEntry.local)
        #expect(entry.id.flatMap(UUID.init(uuidString:)) != nil)
    }
}
