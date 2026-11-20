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

    // MARK: - Meal fpuID

    @Test("A meal with fat or protein gets an fpuID") func testFPUIDAssigned() {
        let meal = CarbsEntry(
            id: UUID().uuidString, createdAt: now, actualDate: now, carbs: 20, fat: 10, protein: 0,
            note: nil, enteredBy: CarbsEntry.local, isFPU: false, fpuID: nil
        )
        let stored = BaseCarbsStorage.withFPUIDIfNeeded(meal)
        #expect(stored.fpuID.flatMap(UUID.init(uuidString:)) != nil)
        #expect(stored.id == meal.id)
        #expect(stored.carbs == meal.carbs && stored.fat == meal.fat && stored.protein == meal.protein)
    }

    @Test("A carbs-only meal or one with an fpuID is unchanged") func testFPUIDKept() {
        let carbsOnly = CarbsEntry(
            id: UUID().uuidString, createdAt: now, actualDate: now, carbs: 20, fat: 0, protein: 0,
            note: nil, enteredBy: CarbsEntry.local, isFPU: false, fpuID: nil
        )
        #expect(BaseCarbsStorage.withFPUIDIfNeeded(carbsOnly).fpuID == nil)

        let fpuID = UUID().uuidString
        let linked = CarbsEntry(
            id: UUID().uuidString, createdAt: now, actualDate: now, carbs: 20, fat: 10, protein: 5,
            note: nil, enteredBy: CarbsEntry.local, isFPU: false, fpuID: fpuID
        )
        #expect(BaseCarbsStorage.withFPUIDIfNeeded(linked).fpuID == fpuID)
    }
}
