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

    @Test("Unlinked carb equivalents deleted with a meal are deleted remotely too") func testSnapshotLinksOrphans() {
        let orphanID = UUID()
        let unlinked = MealSnapshot(id: UUID(), fpuID: nil, date: now, carbs: 20, fat: 30, protein: 10, note: nil)
        #expect(unlinked.linkingCarbEquivalents(orphanID).fpuID == orphanID)
        #expect(unlinked.linkingCarbEquivalents(nil) == unlinked)

        let linked = MealSnapshot(id: UUID(), fpuID: UUID(), date: now, carbs: 20, fat: 30, protein: 10, note: nil)
        #expect(linked.linkingCarbEquivalents(orphanID) == linked, "A meal's own fpuID is never replaced")
    }

    // MARK: - External insulin

    @Test("External insulin is rounded to the increment without a volume cap") func testExternalInsulinRounding() {
        #expect(ExternalInsulin.rounded(40, toIncrement: 0.05) == 40, "40 U taken must not be logged as a pump's 30 U maximum")
        #expect(
            ExternalInsulin
                .rounded(Decimal(string: "2.37")!, toIncrement: Decimal(string: "0.05")!) == Decimal(string: "2.35")!
        )
        #expect(
            ExternalInsulin
                .rounded(Decimal(string: "2.35")!, toIncrement: Decimal(string: "0.05")!) == Decimal(string: "2.35")!
        )
        #expect(ExternalInsulin.rounded(-1, toIncrement: 0.05) == 0)
    }

    @Test("External insulin above max bolus is always confirmed with a warning") func testExternalInsulinConfirmation() {
        #expect(ExternalInsulin.needsExplicitConfirmation(12, maxBolus: 10))
        #expect(!ExternalInsulin.needsExplicitConfirmation(10, maxBolus: 10))

        let plain = BolusIntentRequest.confirmationMessage(requested: 12, deliverable: 12, isExternal: true)
        let warned = BolusIntentRequest.confirmationMessage(requested: 12, deliverable: 12, isExternal: true, aboveMaxBolus: 10)
        #expect(warned.count > plain.count)
        #expect(warned.contains(Decimal(10).formatted()))
    }

    @Test("A failed forecast update after external insulin says the insulin was logged") func testExternalInsulinLoggedMessage() {
        let message = ExternalInsulin.loggedButForecastFailedMessage(
            amount: 4,
            error: NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "timeout"])
        )
        #expect(message.contains(Decimal(4).formatted()))
        #expect(message.contains("timeout"))
    }

    // MARK: - Shortcut bolus

    @Test("Shortcut confirmation names the rounded amount") func testShortcutConfirmationRounded() {
        let message = BolusIntentRequest.confirmationMessage(requested: 2.37, deliverable: 2.35, isExternal: false)
        #expect(message.contains(Decimal(string: "2.35")!.formatted()))
        #expect(message.contains(Decimal(string: "2.37")!.formatted()), "The rounding must be explained")
    }

    @Test("Shortcut confirmation without rounding has no rounding note") func testShortcutConfirmationExact() {
        let message = BolusIntentRequest.confirmationMessage(requested: 2.35, deliverable: 2.35, isExternal: false)
        let rounded = BolusIntentRequest.confirmationMessage(requested: 2.37, deliverable: 2.35, isExternal: false)
        #expect(message.count < rounded.count)
    }

    @Test("Shortcut result reports the real bolus outcome") func testShortcutResult() {
        let enacted = BolusIntentRequest.resultMessage(for: .enacted(message: "ok"), amount: 1.5)
        let failed = BolusIntentRequest.resultMessage(for: .failed(message: "Pump suspended", error: nil), amount: 1.5)
        let unknown = BolusIntentRequest.resultMessage(for: nil, amount: 1.5)

        #expect(enacted != failed)
        #expect(failed.contains("Pump suspended"), "The pump's reason must reach the user")
        #expect(unknown != enacted)
    }

    // MARK: - Treatments

    @Test("A failed bolus after a saved meal says the carbs were saved") func testMealSavedBolusFailedMessage() {
        let failed = Treatments.StateModel.mealSavedBolusFailedMessage(for: .failed(message: "Pump suspended", error: nil))
        #expect(failed.contains("Pump suspended"))
        #expect(Treatments.StateModel.mealSavedBolusFailedMessage(for: nil) != failed)
    }

    @Test("A failed forecast update after saving a meal says the carbs were saved") func testMealSavedForecastFailed() {
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGM warming up"])
        let message = Treatments.StateModel.mealSavedButForecastFailedMessage(error: error)
        #expect(message.contains("CGM warming up"))
        #expect(message.contains("saved"), "The user must learn the carbs are already saved")
    }

    @Test("A failed bolus without a meal shows the pump's reason") func testBolusFailedMessage() {
        let failed = Treatments.StateModel.bolusFailedMessage(for: .failed(message: "Rounds to 0 U", error: nil))
        #expect(failed.contains("Rounds to 0 U"))
        #expect(!Treatments.StateModel.bolusFailedMessage(for: nil).isEmpty)
    }

    // MARK: - History deletion

    private func makeBolus(
        in context: NSManagedObjectContext,
        minutesAgo: Double,
        isSMB: Bool = false,
        isExternal: Bool = false
    ) -> PumpEventStored {
        let event = PumpEventStored(context: context)
        event.id = UUID().uuidString
        event.timestamp = now.addingTimeInterval(-minutesAgo * 60)
        event.type = PumpEventStored.EventType.bolus.rawValue
        let bolus = BolusStored(context: context)
        bolus.amount = 2
        bolus.isSMB = isSMB
        bolus.isExternal = isExternal
        bolus.pumpEvent = event
        return event
    }

    @Test("Deleting active insulin warns, by type") func testHistoryInsulinWarnings() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()
        let activeDuration: TimeInterval = 10 * 60 * 60

        await context.perform {
            func message(_ event: PumpEventStored) -> String {
                History.DeletionTarget.insulin(event)
                    .message(units: .mgdL, insulinActiveDuration: activeDuration, now: self.now) ?? ""
            }
            let base = message(self.makeBolus(in: context, minutesAgo: 11 * 60))
            let pump = message(self.makeBolus(in: context, minutesAgo: 30))
            let smb = message(self.makeBolus(in: context, minutesAgo: 30, isSMB: true))
            let external = message(self.makeBolus(in: context, minutesAgo: 30, isExternal: true))

            #expect(!base.contains("IOB"), "Insulin past its duration of action needs no warning")
            #expect(pump.contains("IOB"))
            #expect(smb.contains("IOB"))
            #expect(external.contains("IOB"))
            #expect(Set([pump, smb, external].map { $0.components(separatedBy: "\n\n").last ?? "" }).count == 3)
        }
    }

    @Test("Deleting carbs still absorbing warns about COB") func testHistoryCarbsWarning() async throws {
        let stack = try await CoreDataStack.createForTests()
        let context = stack.newTaskContext()

        await context.perform {
            func message(hoursAgo: Double) -> String {
                let entry = CarbEntryStored(context: context)
                entry.date = self.now.addingTimeInterval(-hoursAgo * 60 * 60)
                entry.carbs = 30
                return History.DeletionTarget.carbs(entry)
                    .message(units: .mgdL, insulinActiveDuration: 0, now: self.now) ?? ""
            }
            #expect(message(hoursAgo: 1).contains("COB"))
            #expect(!message(hoursAgo: 7).contains("COB"))
        }
    }
}
