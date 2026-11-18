import HealthKit

/// The Health types the backup reads: every quantity and category type the SDK declares that is not deprecated, plus
/// workouts, their routes and electrocardiograms. Characteristic types (date of birth, blood type) are not samples.
enum HealthKitTypes {
    static let quantity: [HKQuantityTypeIdentifier] = [
        .appleSleepingWristTemperature, .bodyFatPercentage, .bodyMass, .bodyMassIndex, .electrodermalActivity,
        .height, .leanBodyMass, .waistCircumference, .activeEnergyBurned, .appleExerciseTime, .appleMoveTime,
        .appleStandTime, .basalEnergyBurned, .crossCountrySkiingSpeed, .cyclingCadence,
        .cyclingFunctionalThresholdPower, .cyclingPower, .cyclingSpeed, .distanceCrossCountrySkiing, .distanceCycling,
        .distanceDownhillSnowSports, .distancePaddleSports, .distanceRowing, .distanceSkatingSports,
        .distanceSwimming, .distanceWalkingRunning, .distanceWheelchair, .estimatedWorkoutEffortScore,
        .flightsClimbed, .paddleSportsSpeed, .physicalEffort, .pushCount, .rowingSpeed, .runningPower, .runningSpeed,
        .stepCount, .swimmingStrokeCount, .underwaterDepth, .workoutEffortScore, .environmentalAudioExposure,
        .environmentalSoundReduction, .headphoneAudioExposure, .atrialFibrillationBurden, .heartRate,
        .heartRateRecoveryOneMinute, .heartRateVariabilityRMSSD, .heartRateVariabilitySDNN,
        .peripheralPerfusionIndex, .restingHeartRate, .vo2Max, .walkingHeartRateAverage, .appleWalkingSteadiness,
        .runningGroundContactTime, .runningStrideLength, .runningVerticalOscillation, .sixMinuteWalkTestDistance,
        .stairAscentSpeed, .stairDescentSpeed, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage,
        .walkingSpeed, .walkingStepLength, .dietaryBiotin, .dietaryCaffeine, .dietaryCalcium,
        .dietaryCarbohydrates, .dietaryChloride, .dietaryCholesterol, .dietaryChromium, .dietaryCopper,
        .dietaryEnergyConsumed, .dietaryFatMonounsaturated, .dietaryFatPolyunsaturated, .dietaryFatSaturated,
        .dietaryFatTotal, .dietaryFiber, .dietaryFolate, .dietaryIodine, .dietaryIron, .dietaryMagnesium,
        .dietaryManganese, .dietaryMolybdenum, .dietaryNiacin, .dietaryPantothenicAcid, .dietaryPhosphorus,
        .dietaryPotassium, .dietaryProtein, .dietaryRiboflavin, .dietarySelenium, .dietarySodium, .dietarySugar,
        .dietaryThiamin, .dietaryVitaminA, .dietaryVitaminB12, .dietaryVitaminB6, .dietaryVitaminC, .dietaryVitaminD,
        .dietaryVitaminE, .dietaryVitaminK, .dietaryWater, .dietaryZinc, .bloodAlcoholContent,
        .bloodPressureDiastolic, .bloodPressureSystolic, .insulinDelivery, .numberOfAlcoholicBeverages,
        .numberOfTimesFallen, .timeInDaylight, .uvExposure, .waterTemperature, .basalBodyTemperature,
        .appleSleepingBreathingDisturbances, .forcedExpiratoryVolume1, .forcedVitalCapacity, .inhalerUsage,
        .oxygenSaturation, .peakExpiratoryFlowRate, .respiratoryRate, .bloodGlucose, .bodyTemperature,
    ]

    static let category: [HKCategoryTypeIdentifier] = [
        .appleStandHour, .environmentalAudioExposureEvent, .headphoneAudioExposureEvent, .highHeartRateEvent,
        .hypertensionEvent, .irregularHeartRhythmEvent, .lowCardioFitnessEvent, .lowHeartRateEvent, .mindfulSession,
        .appleWalkingSteadinessEvent, .handwashingEvent, .toothbrushingEvent, .bleedingAfterMenopause,
        .bleedingAfterPregnancy, .bleedingDuringPregnancy, .cervicalMucusQuality, .contraceptive,
        .infrequentMenstrualCycles, .intermenstrualBleeding, .irregularMenstrualCycles, .lactation,
        .menopausalState, .menstrualFlow, .ovulationTestResult, .persistentIntermenstrualBleeding, .pregnancy,
        .pregnancyTestResult, .progesteroneTestResult, .prolongedMenstrualPeriods, .sexualActivity,
        .sleepApneaEvent, .sleepAnalysis, .abdominalCramps, .acne, .appetiteChanges, .bladderIncontinence, .bloating,
        .breastPain, .chestTightnessOrPain, .chills, .constipation, .coughing, .diarrhea, .dizziness, .drySkin,
        .fainting, .fatigue, .fever, .generalizedBodyAche, .hairLoss, .headache, .heartburn, .hotFlashes,
        .lossOfSmell, .lossOfTaste, .lowerBackPain, .memoryLapse, .moodChanges, .nausea, .nightSweats, .pelvicPain,
        .rapidPoundingOrFlutteringHeartbeat, .runnyNose, .shortnessOfBreath, .sinusCongestion, .skippedHeartbeat,
        .sleepChanges, .soreThroat, .vaginalDryness, .vomiting, .wheezing,
    ]

    static var quantityTypes: [HKQuantityType] {
        quantity.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
    }

    /// The quantity and category types, read one month at a time.
    static var sampleTypes: [HKSampleType] {
        let quantities: [HKSampleType] = quantityTypes
        let categories: [HKSampleType] = category.compactMap { HKCategoryType.categoryType(forIdentifier: $0) }
        return quantities + categories
    }

    /// Everything the upload asks to read.
    static var readable: Set<HKObjectType> {
        var types = Set<HKObjectType>(sampleTypes.map { $0 as HKObjectType })
        types.insert(HKWorkoutType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        types.insert(HKObjectType.electrocardiogramType())
        return types
    }
}
