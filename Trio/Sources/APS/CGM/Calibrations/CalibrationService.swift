import Foundation
import LibreTransmitter
import Swinject

struct Calibration: JSON, Hashable, Identifiable {
    let x: Double
    let y: Double
    var date = Date()
    /// Date of the sensor reading `x` was taken from. `nil` for calibrations saved
    /// before this was recorded.
    var readingDate: Date?

    static let zero = Calibration(x: 0, y: 0)

    var id = UUID()
}

protocol CalibrationService {
    var slope: Double { get }
    var intercept: Double { get }
    var calibrations: [Calibration] { get }

    func addCalibration(_ calibration: Calibration)
    func removeCalibration(_ calibration: Calibration)
    func removeAllCalibrations()
    func removeLast()

    func calibrate(value: Int) -> Double
    /// Calibrates a sensor reading and remembers its raw value, so a later
    /// fingerstick can be paired with the raw value instead of the stored
    /// (already calibrated) one.
    func calibrate(value: Int, readingDate: Date) -> Double
    /// The uncalibrated sensor value behind a stored reading, or `nil` when it
    /// can't be known reliably (the calibration changed since the reading was
    /// stored and its raw value wasn't seen in this session).
    func rawValue(forStoredGlucose storedValue: Int, readingDate: Date) -> Double?
}

final class BaseCalibrationService: CalibrationService, Injectable {
    private enum Config {
        static let minSlope = 0.8
        static let maxSlope = 1.25
        static let minIntercept = -100.0
        static let maxIntercept = 100.0
        static let maxValue = 500.0
        static let minValue = 0.0
        /// Below this variance of the calibration x values (mg/dL²) the points
        /// are effectively one point and a slope can't be fitted.
        static let minXVariance = 1.0
        static let rawReadingRetention: TimeInterval = 60 * 60
        static let rawReadingDateTolerance: TimeInterval = 1
    }

    @Injected() var storage: FileStorage!
    @Injected() var notificationCenter: NotificationCenter!
    private var lifetime = Lifetime()
    private let lock = NSRecursiveLock(label: "BaseCalibrationService.lock")
    private var storedCalibrations: [Calibration] = []
    /// Raw values of recently calibrated readings, keyed by reading date. In memory only.
    private var recentRawReadings: [Date: Int] = [:]
    /// When the calibration last changed in this session. Readings stored before
    /// this were calibrated with different parameters.
    private var calibrationChangedAt: Date = .distantPast

    var calibrations: [Calibration] {
        lock.perform { storedCalibrations }
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        storedCalibrations = storage.retrieve(OpenAPS.Trio.calibrations, as: [Calibration].self) ?? []
        subscribe()
    }

    private func subscribe() {
//        notificationCenter.publisher(for: .newSensorDetected)
//            .sink { [weak self] _ in
//                self?.removeAllCalibrations()
//            }
//            .store(in: &lifetime)
    }

    var slope: Double {
        Self.slope(for: calibrations)
    }

    var intercept: Double {
        Self.intercept(for: calibrations)
    }

    /// Least-squares slope, bounded to `Config.minSlope...Config.maxSlope`.
    ///
    /// Falls back to 1 (no scaling) when fewer than two calibrations exist or
    /// their x values are (nearly) identical, e.g. two fingersticks against the
    /// same sensor reading. The fit is undefined there (0 / 0 = NaN), and NaN
    /// used to turn every calibrated reading into 500 mg/dL.
    static func slope(for calibrations: [Calibration]) -> Double {
        guard calibrations.count >= 2 else {
            return 1
        }

        let xs = calibrations.map(\.x)
        let ys = calibrations.map(\.y)
        let covariance = average(multiply(xs, ys)) - average(xs) * average(ys)
        let variance = average(multiply(xs, xs)) - pow(average(xs), 2)
        guard variance.isFinite, variance >= Config.minXVariance else {
            return 1
        }
        let slope = covariance / variance
        guard slope.isFinite else {
            return 1
        }

        return min(max(slope, Config.minSlope), Config.maxSlope)
    }

    /// Intercept for `slope(for:)`, bounded to `Config.minIntercept...Config.maxIntercept`; 0 when not finite.
    static func intercept(for calibrations: [Calibration]) -> Double {
        guard calibrations.count >= 1 else {
            return 0
        }
        let xs = calibrations.map(\.x)
        let ys = calibrations.map(\.y)

        let intercept = average(ys) - slope(for: calibrations) * average(xs)
        guard intercept.isFinite else {
            return 0
        }

        return min(max(intercept, Config.minIntercept), Config.maxIntercept)
    }

    func calibrate(value: Int) -> Double {
        linearRegression(value)
    }

    func calibrate(value: Int, readingDate: Date) -> Double {
        lock.perform {
            recentRawReadings[readingDate] = value
            let cutoff = Date().addingTimeInterval(-Config.rawReadingRetention)
            recentRawReadings = recentRawReadings.filter { $0.key >= cutoff }
            return linearRegression(value)
        }
    }

    func rawValue(forStoredGlucose storedValue: Int, readingDate: Date) -> Double? {
        lock.perform {
            if let raw = recentRawReadings.first(where: {
                abs($0.key.timeIntervalSince(readingDate)) <= Config.rawReadingDateTolerance
            })?.value {
                return Double(raw)
            }
            // Calibration changed since this reading was stored; inverting the current
            // parameters would give the wrong raw value.
            guard readingDate > calibrationChangedAt else { return nil }
            // A clamped value can't be inverted.
            let stored = Double(storedValue)
            guard stored > Config.minValue, stored < Config.maxValue else { return nil }
            let raw = (stored - intercept) / slope
            return raw.isFinite ? raw : nil
        }
    }

    func addCalibration(_ calibration: Calibration) {
        updateCalibrations { $0.append(calibration) }
    }

    func removeCalibration(_ calibration: Calibration) {
        updateCalibrations { calibrations in calibrations.removeAll { $0 == calibration } }
    }

    func removeAllCalibrations() {
        updateCalibrations { $0.removeAll() }
    }

    func removeLast() {
        updateCalibrations { calibrations in
            guard calibrations.isNotEmpty else { return }
            calibrations.removeLast()
        }
    }

    private func updateCalibrations(_ update: (inout [Calibration]) -> Void) {
        lock.perform {
            let before = storedCalibrations
            update(&storedCalibrations)
            if storedCalibrations != before {
                calibrationChangedAt = Date()
            }
            storage.save(storedCalibrations, as: OpenAPS.Trio.calibrations)
        }
    }

    private static func average(_ input: [Double]) -> Double {
        input.reduce(0, +) / Double(input.count)
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        zip(a, b).map(*)
    }

    /// Calibrated value of a raw reading, bounded to `Config.minValue...Config.maxValue`.
    /// Returns the raw value unchanged if the result is not finite, so a broken
    /// calibration can never be stored as a clamped extreme.
    private func linearRegression(_ x: Int) -> Double {
        lock.perform {
            let calibrated = intercept + slope * Double(x)
            guard calibrated.isFinite else {
                warning(.cgm, "Calibration produced a non-finite value for \(x) mg/dL, using the uncalibrated value")
                return Double(x)
            }
            return calibrated.clamped(Config.minValue ... Config.maxValue)
        }
    }
}
