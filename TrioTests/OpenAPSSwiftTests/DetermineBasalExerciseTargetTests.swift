import Foundation
import Testing
@testable import Trio

/// With "high temp target raises sensitivity" on, `determine-basal.js` turns Dynamic ISF off whenever the
/// current min target is 118 mg/dL or higher, so basal is scaled by the temp-target sensitivity ratio:
/// `basal = current_basal * overrideFactor * sensitivityRatio`, with
/// `sensitivityRatio = c / (c + target - 100)` and `c = half_basal_exercise_target - 100`.
@Suite("determineBasal with an exercise target and Dynamic ISF") struct DetermineBasalExerciseTargetTests {
    private struct Inputs {
        var profile: Profile
        var preferences: Preferences
        var currentTemp: TempBasal
        var iobData: [IobResult]
        var mealData: ComputedCarbs
        var autosensData: Autosens
        var glucoseStatus: GlucoseStatus
        var trioCustomOrefVariables: TrioCustomOrefVariables
        var currentTime: Date
    }

    /// Glucose sits flat on `target` with no insulin on board, so the loop lands in the
    /// "in range: setting current basal as temp" branch and the enacted rate is the adjusted basal.
    private func buildInputs(
        target: Decimal,
        tempTargetSet: Bool,
        raisesSensitivity: Bool,
        sigmoid: Bool,
        tddAdjBasal: Bool,
        weightedAverageTDD: Decimal = 30,
        overrideTarget: Decimal = 0
    ) -> Inputs {
        let now = Date()

        var profile = Profile()
        profile.currentBasal = 1.0
        profile.maxDailyBasal = 1.0
        profile.maxBasal = 3.0
        profile.minBg = tempTargetSet ? target : 100
        profile.maxBg = tempTargetSet ? target : 100
        profile.temptargetSet = tempTargetSet
        profile.sens = 40
        profile.carbRatio = 10
        profile.thresholdSetting = 70
        profile.maxIob = 6
        profile.bolusIncrement = 0.1
        profile.halfBasalExerciseTarget = 160
        profile.highTemptargetRaisesSensitivity = raisesSensitivity
        profile.tddAdjBasal = tddAdjBasal
        profile.outUnits = .mgdL

        var preferences = Preferences()
        preferences.curve = .rapidActing
        preferences.useCustomPeakTime = false
        preferences.useNewFormula = true
        preferences.sigmoid = sigmoid
        preferences.adjustmentFactor = 0.8
        preferences.adjustmentFactorSigmoid = 0.5

        let currentTemp = TempBasal(duration: 0, rate: 0, temp: .absolute, timestamp: now)

        let iobData = [IobResult(
            iob: 0,
            activity: 0,
            basaliob: 0,
            bolusiob: 0,
            netbasalinsulin: 0,
            bolusinsulin: 0,
            time: now,
            iobWithZeroTemp: IobResult.IobWithZeroTemp(
                iob: 0,
                activity: 0,
                basaliob: 0,
                bolusiob: 0,
                netbasalinsulin: 0,
                bolusinsulin: 0,
                time: now
            ),
            lastBolusTime: 0,
            lastTemp: IobResult.LastTemp(
                rate: 0,
                timestamp: now,
                started_at: now,
                date: UInt64(now.timeIntervalSince1970 * 1000),
                duration: 30
            )
        )]

        let mealData = ComputedCarbs(
            carbs: 0,
            mealCOB: 0,
            currentDeviation: 0,
            maxDeviation: 0,
            minDeviation: 0,
            slopeFromMaxDeviation: 0,
            slopeFromMinDeviation: 0,
            allDeviations: [0, 0, 0, 0, 0],
            lastCarbTime: 0
        )

        let glucoseStatus = GlucoseStatus(
            delta: 0,
            glucose: target,
            noise: 1,
            shortAvgDelta: 0,
            longAvgDelta: 0,
            date: now,
            lastCalIndex: nil,
            device: "test"
        )

        let trioCustomOrefVariables = TrioCustomOrefVariables(
            average_total_data: 30,
            weightedAverage: weightedAverageTDD,
            currentTDD: 30,
            past2hoursAverage: 0,
            date: now,
            overridePercentage: 100,
            useOverride: overrideTarget != 0,
            duration: 0,
            unlimited: true,
            overrideTarget: overrideTarget,
            smbIsOff: false,
            advancedSettings: false,
            isfAndCr: false,
            isf: true,
            cr: true,
            smbIsScheduledOff: false,
            start: 0,
            end: 0,
            smbMinutes: 30,
            uamMinutes: 30
        )

        return Inputs(
            profile: profile,
            preferences: preferences,
            currentTemp: currentTemp,
            iobData: iobData,
            mealData: mealData,
            autosensData: Autosens(ratio: 1.0, newisf: nil),
            glucoseStatus: glucoseStatus,
            trioCustomOrefVariables: trioCustomOrefVariables,
            currentTime: now
        )
    }

    private func determine(_ inputs: Inputs) throws -> Determination? {
        try DeterminationGenerator.determineBasal(
            profile: inputs.profile,
            preferences: inputs.preferences,
            currentTemp: inputs.currentTemp,
            iobData: inputs.iobData,
            mealData: inputs.mealData,
            autosensData: inputs.autosensData,
            glucoseStatus: inputs.glucoseStatus,
            microBolusAllowed: false,
            trioCustomOrefVariables: inputs.trioCustomOrefVariables,
            currentTime: inputs.currentTime
        )
    }

    @Test(
        "Exercise temp target turns Dynamic ISF off and scales basal by the temp-target ratio",
        arguments: [
            // target, sigmoid, tddAdjBasal, expected sensitivityRatio (60 / (60 + target - 100))
            (Decimal(140), false, false, Decimal(string: "0.6")!),
            (Decimal(140), true, false, Decimal(string: "0.6")!),
            (Decimal(140), true, true, Decimal(string: "0.6")!),
            (Decimal(160), false, false, Decimal(string: "0.5")!),
            (Decimal(160), true, true, Decimal(string: "0.5")!)
        ]
    ) func exerciseTempTargetReducesBasal(
        target: Decimal,
        sigmoid: Bool,
        tddAdjBasal: Bool,
        expectedRatio: Decimal
    ) throws {
        // A 24h TDD above the 14-day average would raise basal by the TDD ratio if Dynamic ISF stayed on.
        let inputs = buildInputs(
            target: target,
            tempTargetSet: true,
            raisesSensitivity: true,
            sigmoid: sigmoid,
            tddAdjBasal: tddAdjBasal,
            weightedAverageTDD: 36
        )

        let determination = try #require(try determine(inputs))

        #expect(determination.sensitivityRatio == expectedRatio)
        #expect(determination.rate == expectedRatio * inputs.profile.currentBasal!)
        #expect(determination.duration == 30)
        #expect(!determination.reason.contains("Dynamic ISF: On"))
    }

    @Test("No exercise setting: high temp target keeps Dynamic ISF on") func highTempTargetWithoutExerciseSetting() throws {
        let inputs = buildInputs(
            target: 140,
            tempTargetSet: true,
            raisesSensitivity: false,
            sigmoid: true,
            tddAdjBasal: false
        )

        let determination = try #require(try determine(inputs))

        #expect(determination.rate == inputs.profile.currentBasal)
        #expect(determination.reason.contains("Dynamic ISF: On"))
    }

    @Test("No exercise setting: TDD-adjusted basal still applies") func highTempTargetWithoutExerciseSettingKeepsTddBasal() throws {
        let inputs = buildInputs(
            target: 140,
            tempTargetSet: true,
            raisesSensitivity: false,
            sigmoid: true,
            tddAdjBasal: true,
            weightedAverageTDD: 36
        )

        let determination = try #require(try determine(inputs))

        // tdd24h_14d_Ratio = 36 / 30 = 1.2, capped at autosens max 1.2
        #expect(determination.rate == Decimal(string: "1.2"))
        #expect(determination.reason.contains("Dynamic ISF: On"))
    }

    @Test("Exercise setting with a high override target uses the autosens ratio") func highOverrideTargetTurnsDynamicIsfOff() throws {
        let inputs = buildInputs(
            target: 130,
            tempTargetSet: false,
            raisesSensitivity: true,
            sigmoid: true,
            tddAdjBasal: true,
            weightedAverageTDD: 36,
            overrideTarget: 130
        )

        let determination = try #require(try determine(inputs))

        // No temp target, so the ratio is the autosens ratio (1.0) rather than the TDD ratio (1.2).
        #expect(determination.sensitivityRatio == 1)
        #expect(determination.rate == inputs.profile.currentBasal)
        #expect(!determination.reason.contains("Dynamic ISF: On"))
    }
}
