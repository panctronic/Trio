import Foundation
import Swinject
import Testing

@testable import Trio

@Suite("Calibration Service Tests", .serialized) @MainActor struct CalibrationTests: Injectable {
    let fileStorage = BaseFileStorage()
    @Injected() var calibrationService: CalibrationService!
    let resolver = TrioApp.resolver

    init() {
        injectServices(resolver)
    }

    @Test("Can create simple calibration") func testCreateSimpleCalibration() {
        // Given
        calibrationService.removeAllCalibrations()
        let calibration = Calibration(x: 100.0, y: 102.0)

        // When
        calibrationService.addCalibration(calibration)

        // Then
        #expect(calibrationService.calibrations.isNotEmpty)
        #expect(calibrationService.slope == 1)
        #expect(calibrationService.intercept == 2)
        #expect(calibrationService.calibrate(value: 104) == 106)
    }

    @Test("Can handle multiple calibrations") func testCreateMultipleCalibration() {
        // Given
        calibrationService.removeAllCalibrations()
        let calibration = Calibration(x: 100.0, y: 120)
        let calibration2 = Calibration(x: 120.0, y: 130.0)

        // When
        calibrationService.addCalibration(calibration)
        calibrationService.addCalibration(calibration2)

        // Then
        #expect(abs(calibrationService.slope - 0.8) < 0.0001)
        #expect(abs(calibrationService.intercept - 37) < 0.0001)
        #expect(abs(calibrationService.calibrate(value: 80) - 101) < 0.0001)

        // When removing last
        calibrationService.removeLast()
        #expect(calibrationService.calibrations.count == 1)

        // When removing all
        calibrationService.removeAllCalibrations()
        #expect(calibrationService.calibrations.isEmpty)
    }

    @Test("Handles calibration bounds correctly") func testCalibrationBounds() {
        // Given
        calibrationService.removeAllCalibrations()

        // When no calibrations exist
        #expect(calibrationService.slope == 1, "Default slope should be 1")
        #expect(calibrationService.intercept == 0, "Default intercept should be 0")

        // When adding extreme values
        let extremeCalibration1 = Calibration(x: 0.0, y: 1000.0) // Should be clamped
        let extremeCalibration2 = Calibration(x: 1000.0, y: 0.0) // Should be clamped

        calibrationService.addCalibration(extremeCalibration1)
        calibrationService.addCalibration(extremeCalibration2)

        // Then check bounds
        #expect(calibrationService.slope >= 0.8, "Slope should not be less than minimum")
        #expect(calibrationService.slope <= 1.25, "Slope should not be more than maximum")
        #expect(calibrationService.intercept >= -100, "Intercept should not be less than minimum")
        #expect(calibrationService.intercept <= 100, "Intercept should not be more than maximum")
    }

    @Test("Concurrent calibrate and remove all do not race") func testConcurrentCalibrateAndRemoveAll() {
        let service = BaseCalibrationService(resolver: resolver)
        service.removeAllCalibrations()

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            switch index % 3 {
            case 0:
                service.addCalibration(Calibration(x: 100.0, y: 110.0))
            case 1:
                service.removeAllCalibrations()
            default:
                let value = service.calibrate(value: 120)
                #expect(value >= 0 && value <= 500)
            }
        }

        service.removeAllCalibrations()
        #expect(service.calibrations.isEmpty)
    }

    // MARK: - Degenerate fits

    @Test("Two calibrations against the same reading fall back to an offset, not NaN") func testDuplicateX() {
        let calibrations = [Calibration(x: 120, y: 140), Calibration(x: 120, y: 150)]

        let slope = BaseCalibrationService.slope(for: calibrations)
        let intercept = BaseCalibrationService.intercept(for: calibrations)

        #expect(slope == 1)
        #expect(intercept == 25)
    }

    @Test("Nearly identical x values don't produce a runaway slope") func testNearlyDuplicateX() {
        let calibrations = [Calibration(x: 120, y: 100), Calibration(x: 120.5, y: 200)]

        #expect(BaseCalibrationService.slope(for: calibrations) == 1)
        #expect(BaseCalibrationService.intercept(for: calibrations).isFinite)
    }

    @Test("A single calibration is a pure offset") func testSingleCalibration() {
        let calibrations = [Calibration(x: 100, y: 90)]

        #expect(BaseCalibrationService.slope(for: calibrations) == 1)
        #expect(BaseCalibrationService.intercept(for: calibrations) == -10)
    }

    @Test("Non-finite calibration input falls back to identity") func testNaNInput() {
        let calibrations = [Calibration(x: .nan, y: 100), Calibration(x: 120, y: 130)]

        #expect(BaseCalibrationService.slope(for: calibrations) == 1)
        #expect(BaseCalibrationService.intercept(for: calibrations) == 0)
    }

    @Test("Normal three point fit") func testThreePointFit() {
        // y = 1.1x - 5
        let calibrations = [
            Calibration(x: 80, y: 83),
            Calibration(x: 120, y: 127),
            Calibration(x: 200, y: 215)
        ]

        #expect(abs(BaseCalibrationService.slope(for: calibrations) - 1.1) < 0.0001)
        #expect(abs(BaseCalibrationService.intercept(for: calibrations) - -5) < 0.0001)
    }

    @Test("Duplicate-x calibrations never calibrate a reading to the 500 mg/dL bound") func testDuplicateXCalibrate() {
        let service = BaseCalibrationService(resolver: resolver)
        service.removeAllCalibrations()
        service.addCalibration(Calibration(x: 110, y: 120))
        service.addCalibration(Calibration(x: 110, y: 124))

        #expect(service.calibrate(value: 100) == 112)
        service.removeAllCalibrations()
    }

    @Test("clamped leaves NaN alone instead of returning the upper bound") func testClampedNaN() {
        #expect(Double.nan.clamped(0 ... 500).isNaN)
        #expect(Double(600).clamped(0 ... 500) == 500)
        #expect(Double(-1).clamped(0 ... 500) == 0)
        #expect(Double(42).clamped(0 ... 500) == 42)
    }

    @Test("Remove last on an empty list does nothing") func testRemoveLastEmpty() {
        let service = BaseCalibrationService(resolver: resolver)
        service.removeAllCalibrations()
        service.removeLast()
        #expect(service.calibrations.isEmpty)
    }

    // MARK: - Raw values

    @Test("Calibration pairs the fingerstick with the raw sensor value") func testRawValueFromRecordedReading() {
        let service = BaseCalibrationService(resolver: resolver)
        service.removeAllCalibrations()
        service.addCalibration(Calibration(x: 100, y: 120)) // +20 offset

        let readingDate = Date()
        let stored = service.calibrate(value: 150, readingDate: readingDate)
        #expect(stored == 170)

        #expect(service.rawValue(forStoredGlucose: Int(stored), readingDate: readingDate) == 150)
        service.removeAllCalibrations()
    }

    @Test("Raw value is unknown when the calibration changed after an unseen reading") func testRawValueUnknownAfterChange() {
        let service = BaseCalibrationService(resolver: resolver)
        service.removeAllCalibrations()
        let readingDate = Date().addingTimeInterval(-60)
        service.addCalibration(Calibration(x: 100, y: 120))

        #expect(service.rawValue(forStoredGlucose: 170, readingDate: readingDate) == nil)
        service.removeAllCalibrations()
    }

    @Test("Raw value of a reading stored after the last change is the inverted calibration") func testRawValueInverted() {
        let service = BaseCalibrationService(resolver: resolver)
        service.removeAllCalibrations()
        service.addCalibration(Calibration(x: 100, y: 120))
        let readingDate = Date().addingTimeInterval(5)

        #expect(service.rawValue(forStoredGlucose: 170, readingDate: readingDate) == 150)
        // A clamped value can't be inverted
        #expect(service.rawValue(forStoredGlucose: 500, readingDate: readingDate) == nil)
        service.removeAllCalibrations()
    }

    @Test("A second calibration against the same reading is rejected") func testValidateDuplicateReading() {
        let readingDate = Date()
        let existing = [Calibration(x: 120, y: 130, readingDate: readingDate)]

        #expect(
            Calibrations.StateModel.validateCalibration(readingDate: readingDate, rawValue: 120, existing: existing) ==
                .readingAlreadyCalibrated
        )
        #expect(
            Calibrations.StateModel.validateCalibration(
                readingDate: readingDate.addingTimeInterval(300),
                rawValue: 120,
                existing: existing
            ) == .valid(raw: 120)
        )
        #expect(
            Calibrations.StateModel.validateCalibration(readingDate: readingDate, rawValue: nil, existing: []) ==
                .rawValueUnknown
        )
    }

    @Test("Overcalibration keeps raw readings when the calibration is fine") func testOvercalibrateEntries() {
        let service = BaseCalibrationService(resolver: resolver)
        service.removeAllCalibrations()
        service.addCalibration(Calibration(x: 100, y: 110))
        let entry = BloodGlucose(sgv: 120, date: 0, dateString: Date(), glucose: 120)

        let result = BaseFetchGlucoseManager.overcalibrate(entries: [entry], with: service)

        #expect(result.first?.glucose == 130)
        #expect(result.first?.sgv == 130)
        service.removeAllCalibrations()
    }
}
