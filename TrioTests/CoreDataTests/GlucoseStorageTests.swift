import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

@Suite("GlucoseStorage Tests", .serialized) struct GlucoseStorageTests: Injectable {
    @Injected() var storage: GlucoseStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        // Create test context
        // As we are only using this single test context to initialize our in-memory DeterminationStorage we need to perform the Unit Tests serialized
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        // Create assembler with test assembly
        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext) // Add our test assembly last to override Storage
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    @Test("Storage is correctly initialized") func testStorageInitialization() {
        // Verify storage exists
        #expect(storage != nil, "GlucoseStorage should be injected")

        // Verify it's the correct type
        #expect(storage is BaseGlucoseStorage, "Storage should be of type BaseGlucoseStorage")
    }

    @Test("Store and retrieve glucose entries") func testStoreAndRetrieveGlucose() async throws {
        // Given
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 126)
        ]

        // When
        try await storage.storeGlucose(testGlucose)

        // Then verify stored entries
        let storedEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 126"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        #expect(storedEntries?.isEmpty == false, "Should have stored entries")
        #expect(storedEntries?.count == 1, "Should have exactly one entry")
        #expect(storedEntries?[0].glucose == 126, "Glucose value should match")
        #expect(storedEntries?[0].direction == "Flat", "Direction should match")
    }

    @Test("Delete glucose entry") func testDeleteGlucose() async throws {
        // Given
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 140)
        ]
        try await storage.storeGlucose(testGlucose)

        // Get the stored entry's ObjectID
        let storedEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        guard let objectID = storedEntries?.first?.objectID else {
            throw TestError("Failed to get stored entry's ObjectID")
        }

        #expect(storedEntries.isNotNilNotEmpty == true, "Should have exactly one (test) entry")

        // When
        await storage.deleteGlucose(objectID)

        // Then verify deletion
        let remainingEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        #expect(remainingEntries?.isEmpty == true, "Should have no entries after deletion")

        // Finally verify that it stored a copy
        let archivedEntries = try await coreDataStack.fetchObjects(
            ofType: DeletedGlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 140"),
            key: "date",
            ascending: false
        ) as [DeletedGlucoseStored]?

        #expect(archivedEntries?.isEmpty == false, "Should have archived entries after deletion")
    }

    @Test("Get glucose not yet uploaded to Nightscout") func testGetGlucoseNotYetUploadedToNightscout() async throws {
        // Given
        let wholeSeconds = Int64(Date().timeIntervalSince1970)
        let date = Date(timeIntervalSince1970: TimeInterval(wholeSeconds) + 0.2038)
        let expectedMilliseconds = Decimal(wholeSeconds * 1000 + 204)
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: date, glucose: 160)
        ]
        try await storage.storeGlucose(testGlucose)
        try await testContext.perform {
            let manualGlucose = GlucoseStored(context: testContext)
            manualGlucose.id = UUID()
            manualGlucose.date = date
            manualGlucose.glucose = 161
            manualGlucose.isManual = true
            manualGlucose.isUploadedToNS = false
            manualGlucose.isUploadedToHealth = false
            manualGlucose.isUploadedToTidepool = false
            try testContext.save()
        }

        // When
        let notUploadedEntries = try await storage.getGlucoseNotYetUploadedToNightscout()

        // Then
        let sensorEntry = notUploadedEntries.first { $0.sgv == 160 }
        #expect(sensorEntry != nil, "Should have the sensor entry not uploaded to NS")
        #expect(sensorEntry?.date == expectedMilliseconds, "Sensor date should use integer milliseconds")
        #expect(sensorEntry?.dateString == date, "Sensor date fields should represent the same instant")

        let manualEntry = notUploadedEntries.first { $0.mbg == 161 }
        #expect(manualEntry != nil, "Should have the manual entry not uploaded to NS")
        #expect(manualEntry?.date == expectedMilliseconds, "Manual date should use integer milliseconds")
        #expect(manualEntry?.dateString == date, "Manual date fields should represent the same instant")
        #expect(manualEntry?.type == "mbg", "Manual entry type should remain unchanged")
    }

    @Test("Sub-39 glucose is clamped to 39 on storeGlucose") func testStoreGlucoseClampsBelowMinimum() async throws {
        // Given a CGM reading below the 39 mg/dL floor (e.g. LibreTransmitter delivering 23)
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 23)
        ]

        // When
        try await storage.storeGlucose(testGlucose)

        // Then the stored row should be clamped to 39, not 23
        let clampedEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 39"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        #expect(clampedEntries?.count == 1, "Sub-39 glucose should be clamped and stored as 39")

        let rawEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 23"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        #expect(rawEntries?.isEmpty == true, "Raw sub-39 value must not be persisted")
    }

    @Test("Sub-39 glucose is clamped to 39 on backfillGlucose") func testBackfillGlucoseClampsBelowMinimum() async throws {
        // Given a backfilled CGM reading below the 39 mg/dL floor
        let backfillDate = Date().addingTimeInterval(-30 * 60)
        let testGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 456, dateString: backfillDate, glucose: 28)
        ]

        // When
        try await storage.backfillGlucose(testGlucose)

        // Then the backfilled row should be clamped to 39
        let clampedEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 39"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        #expect(clampedEntries?.count == 1, "Sub-39 backfilled glucose should be clamped and stored as 39")
    }

    @Test("Manual glucose does not advance CGM sync dates") func testSyncDateIgnoresManualGlucose() async throws {
        // Given a CGM reading followed by a manual entry 3 minutes later
        let cgmDate = Date().addingTimeInterval(-5 * 60)
        try await storage.storeGlucose([
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 789, dateString: cgmDate, glucose: 110)
        ])
        try await insertManualGlucose(112, at: cgmDate.addingTimeInterval(3 * 60))

        // When
        let syncDate = storage.syncDate()

        // Then the next CGM reading is not filtered as too frequent
        #expect(abs(syncDate.timeIntervalSince(cgmDate)) < 1, "syncDate should be the last CGM reading")
        let lastDate = try #require(storage.lastGlucoseDate())
        #expect(abs(lastDate.timeIntervalSince(cgmDate)) < 1, "lastGlucoseDate should be the last CGM reading")
        let next = BloodGlucose(direction: .flat, date: 790, dateString: cgmDate.addingTimeInterval(5 * 60), glucose: 108)
        #expect(storage.filterTooFrequentGlucose([next], at: syncDate).count == 1)
    }

    @Test("Backfill is not deduplicated against manual glucose") func testBackfillIgnoresManualGlucose() async throws {
        // Given a manual entry 1 minute after a missed CGM reading
        let backfillDate = Date().addingTimeInterval(-20 * 60)
        try await insertManualGlucose(150, at: backfillDate.addingTimeInterval(60))

        // When
        try await storage.backfillGlucose([
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 791, dateString: backfillDate, glucose: 147)
        ])

        // Then the backfilled CGM reading is stored
        let backfilled = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 147 AND isManual == NO"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        #expect(backfilled?.count == 1, "Backfilled CGM reading near a manual entry should be stored")
    }

    @Test("A future-dated reading is not the latest reading") func testFutureDatedGlucoseIgnored() async throws {
        // Given a real reading 5 minutes ago and a stored reading dated 30 minutes ahead
        let realDate = Date().addingTimeInterval(-5 * 60)
        let futureDate = Date().addingTimeInterval(30 * 60)
        try await storage.storeGlucose([BloodGlucose(direction: .flat, date: 800, dateString: realDate, glucose: 101)])
        try await storage.storeGlucose([BloodGlucose(direction: .flat, date: 801, dateString: futureDate, glucose: 250)])

        // Then sync dates and the algorithm only see the real reading
        #expect(abs(storage.syncDate().timeIntervalSince(realDate)) < 1)
        let lastDate = try #require(storage.lastGlucoseDate())
        #expect(abs(lastDate.timeIntervalSince(realDate)) < 1)
        let algorithmGlucose = try await storage.getGlucoseForAlgorithm(shouldSmoothGlucose: false, fetchHours: 1)
        // The in-memory store may hold readings from other tests in this suite
        #expect(algorithmGlucose.contains { $0.sgv == 101 })
        #expect(!algorithmGlucose.contains { $0.sgv == 250 })
        #expect(algorithmGlucose.allSatisfy { $0.dateString <= Date().addingTimeInterval(60) })
    }

    @Test("Readings dated more than a minute ahead are dropped at ingestion") func testDropFutureDatedGlucose() {
        let now = Date()
        let readings = [
            BloodGlucose(sgv: 100, date: 1, dateString: now.addingTimeInterval(-300), glucose: 100),
            BloodGlucose(sgv: 101, date: 2, dateString: now.addingTimeInterval(30), glucose: 101),
            BloodGlucose(sgv: 102, date: 3, dateString: now.addingTimeInterval(61), glucose: 102),
            BloodGlucose(sgv: 103, date: 4, dateString: now.addingTimeInterval(30 * 60), glucose: 103)
        ]

        let (kept, dropped) = BaseFetchGlucoseManager.dropFutureDatedGlucose(readings, now: now)

        #expect(kept.map(\.glucose) == [100, 101])
        #expect(dropped.map(\.glucose) == [102, 103])
    }

    private func insertManualGlucose(_ glucose: Int16, at date: Date) async throws {
        try await testContext.perform {
            let manualGlucose = GlucoseStored(context: testContext)
            manualGlucose.id = UUID()
            manualGlucose.date = date
            manualGlucose.glucose = glucose
            manualGlucose.isManual = true
            try testContext.save()
        }
    }

    @Test(
        "Test glucose alarms",
        .enabled(if: false, "Flaky test, disabled while investigating")
    ) func testGlucoseAlarms() async throws {
        // Given
        let lowGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 55)
        ]
        let highGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 271)
        ]
        let normalGlucose = [
            BloodGlucose(direction: BloodGlucose.Direction.flat, date: 123, dateString: Date(), glucose: 100)
        ]

        // When - Test low glucose
        try await storage.storeGlucose(lowGlucose)
        var storedEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 55"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        // Then
        #expect(storedEntries?.first?.glucose == 55, "Low glucose value should match")
        #expect(storage.alarm == .low, "Should trigger low glucose alarm") // default low limit is 72 mg/dL

        // When - Test high glucose
        try await storage.storeGlucose(highGlucose)
        storedEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 271"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        // Then
        #expect(storedEntries?.first?.glucose == 271, "High glucose value should match")
        #expect(storage.alarm == .high, "Should trigger high glucose alarm") // default high limit is 270 mg/dL

        // When - Test normal glucose
        try await storage.storeGlucose(normalGlucose)
        storedEntries = try await coreDataStack.fetchObjects(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 100"),
            key: "date",
            ascending: false
        ) as [GlucoseStored]?

        // Then
        #expect(storedEntries?.first?.glucose == 100, "Normal glucose value should match")
        #expect(storage.alarm == nil, "Should not trigger any alarm")
    }

    @Test("Upload queries cover each service's backlog window, oldest first") func testUploadBacklogWindows() async throws {
        let now = Date()
        let daysAgo: [Double] = [0.1, 2, 6, 10, 29, 35]
        try await testContext.perform {
            for (index, days) in daysAgo.enumerated() {
                let entry = GlucoseStored(context: testContext)
                entry.id = UUID()
                entry.date = now.addingTimeInterval(-days * 24 * 3600)
                entry.glucose = Int16(200 + index)
                entry.isManual = false
                entry.isUploadedToNS = false
                entry.isUploadedToHealth = false
                entry.isUploadedToTidepool = false
            }
            try testContext.save()
        }

        // Nightscout: 7 days, so the 2- and 6-day-old readings that a 24 h window missed are included.
        let nightscout = try await storage.getGlucoseNotYetUploadedToNightscout().compactMap(\.sgv)
        #expect(nightscout == [202, 201, 200])

        // Apple Health and Tidepool: 30 days.
        let health = try await storage.getGlucoseNotYetUploadedToHealth().compactMap(\.sgv)
        #expect(health == [204, 203, 202, 201, 200])
        let tidepool = try await storage.getGlucoseNotYetUploadedToTidepool()
        #expect(tidepool.count == 5)
        #expect(tidepool.map(\.startDate) == tidepool.map(\.startDate).sorted())
    }

    @Test("Sensor changes marked as uploaded are not offered again") func testCGMStateMarkedUploaded() async throws {
        let fileStorage = try #require(resolver.resolve(FileStorage.self))
        // Whole seconds, so the dates survive the JSON round trip through the files unchanged.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        func sensorChange(_ hoursAgo: Double) -> NightscoutTreatment {
            NightscoutTreatment(
                duration: nil, rawDuration: nil, rawRate: nil, absolute: nil, rate: nil,
                eventType: .nsSensorChange, createdAt: now.addingTimeInterval(-hoursAgo * 3600),
                enteredBy: NightscoutTreatment.local, bolus: nil, insulin: nil, notes: nil,
                carbs: nil, fat: nil, protein: nil, targetTop: nil, targetBottom: nil
            )
        }
        let older = sensorChange(240)
        let newer = sensorChange(2)
        let expired = sensorChange(1000) // no longer in the CGM state file
        await fileStorage.saveAsync([older, newer], as: OpenAPS.Monitor.cgmState)
        await fileStorage.saveAsync([expired], as: OpenAPS.Nightscout.uploadedCGMState)
        defer {
            fileStorage.remove(OpenAPS.Monitor.cgmState)
            fileStorage.remove(OpenAPS.Nightscout.uploadedCGMState)
        }

        #expect(try await storage.getCGMStateNotYetUploadedToNightscout().count == 2)

        await storage.markCGMStateUploadedToNightscout([older])
        let pending = try await storage.getCGMStateNotYetUploadedToNightscout()
        #expect(pending.map(\.createdAt) == [newer.createdAt])

        await storage.markCGMStateUploadedToNightscout(pending)
        #expect(try await storage.getCGMStateNotYetUploadedToNightscout().isEmpty)

        // The uploaded list only keeps entries still present in the CGM state file.
        let uploaded = await fileStorage.retrieveAsync(OpenAPS.Nightscout.uploadedCGMState, as: [NightscoutTreatment].self)
        #expect(uploaded?.map(\.createdAt) == [older.createdAt, newer.createdAt])
    }

    /* Commenting out while we don't have getGlucoseStatus defined
     @Test("getGlucoseStatus returns correct deltas for 0/5/15/30m readings") func testGetGlucoseStatusFourPoints() async throws {
         let now = Date()
         // Prepare 4 readings: at 0, 5, 15, and 30 minutes ago
         let specs: [(offset: TimeInterval, value: Int)] = [
             (0, 100), // now
             (5 * 60, 110), // 5m ago
             (15 * 60, 120), // 15m ago
             (30 * 60, 130) // 30m ago
         ]

         // Insert them into CoreData so that our fetch predicate picks them up
         for (offset, value) in specs {
             await testContext.perform {
                 let glucoseToStore = GlucoseStored(context: testContext)
                 glucoseToStore.id = UUID()
                 glucoseToStore.date = now.addingTimeInterval(-offset)
                 glucoseToStore.glucose = Int16(value)
             }
         }
         try testContext.save()

         // Call the method under test
         let status = try await storage.getGlucoseStatus()
         #expect(status != nil, "Expected non‐nil status")

         // “Now” glucose is the 0m reading
         #expect(status!.glucose == 100)

         // lastDelta: only the 5m point: (100–110)/5*5 = –10
         #expect(status!.delta == -10)

         // shortAvgDelta: average of 5m and 15m windows:
         //   5m window:   (100–110)/5*5   = –10
         //   15m window: (100–120)/15*5 ≈ –6.6667 → –6.67
         //   avg ≈ (–10 + –6.67)/2 = –8.333… → rounded to –8.33
         #expect(status!.shortAvgDelta == -8.33)

         // longAvgDelta: only the 30m window: (100–130)/30*5 = –5
         #expect(status!.longAvgDelta == -5)
     }*/
}
