import Foundation

// Shared value types. Every layer (FIT extraction, session, HealthKit, UI) speaks these.
// Keep them plain, Sendable, Codable, and free of framework imports.

// MARK: - Device

public struct DeviceInfo: Sendable, Codable, Hashable {
    public var protocolVersion: Int
    public var productNumber: Int
    public var unitNumber: UInt32
    public var softwareVersion: Int
    public var maxPacketSize: Int
    public var bluetoothName: String
    public var deviceName: String
    public var deviceModel: String

    public init(protocolVersion: Int, productNumber: Int, unitNumber: UInt32, softwareVersion: Int,
                maxPacketSize: Int, bluetoothName: String, deviceName: String, deviceModel: String) {
        self.protocolVersion = protocolVersion
        self.productNumber = productNumber
        self.unitNumber = unitNumber
        self.softwareVersion = softwareVersion
        self.maxPacketSize = maxPacketSize
        self.bluetoothName = bluetoothName
        self.deviceName = deviceName
        self.deviceModel = deviceModel
    }

    /// e.g. 1234 -> "12.34"
    public var softwareVersionString: String { String(format: "%d.%02d", softwareVersion / 100, softwareVersion % 100) }
}

/// Mirrors Gadgetbridge's GarminCapability; rawValue = bit index in the CONFIGURATION (5050) bitmask.
public enum GarminCapability: Int, Sendable, Codable, CaseIterable {
    case connectMobileFitLink = 0, golfFitLink, vivokidJrFitLink, sync, deviceInitiatesSync,
    hostInitiatedSyncRequests, gncs, advancedMusicControls, findMyPhone, findMyWatch,
    connectiqHttp, connectiqSettings, connectiqWatchAppDownload, connectiqWidgetDownload, connectiqWatchFaceDownload,
    connectiqDataFieldDownload, connectiqAppManagement, courseDownload, workoutDownload, golfCourseDownload,
    deltaSoftwareUpdateFiles, fitpay, livetrack, livetrackAutoStart, livetrackMessaging,
    groupLivetrack, weatherConditions, weatherAlerts, gpsEphemerisDownload, explicitArchive,
    swingSensor, swingSensorRemote, incidentDetection, trueup, instantInput,
    segments, audioPromptLap, audioPromptPaceSpeed, audioPromptHeartRate, audioPromptPower,
    audioPromptNavigation, audioPromptCadence, sportGeneric, sportRunning, sportCycling,
    sportTransition, sportFitnessEquipment, sportSwimming, stopSyncAfterSoftwareUpdate, calendar,
    wifiSetup, smsNotifications, basicMusicControls, audioPromptsSpeech, deltaSoftwareUpdates,
    garminDeviceInfoFileType, sportProfileSetup, hsaSupport, sportStrength, sportCardio,
    unionPay, ipass, ciqAudioContentProvider, unionPayInternational, requestPairFlow,
    locationUpdate, lteSupport, deviceDrivenLivetrackSupport, customCannedTextListSupport, exploreSync,
    incidentDetectAndAssistance, currentTimeRequestSupport, contactsSupport, launchRemoteCiqAppSupport, deviceMessages,
    waypointTransfer, multiLinkService, oauthCredentials, golf9Plus9, antiTheftAlarm,
    inreach, eventSharing, hsaFeatureMessage, handsCalibration, locationUpdateProvider,
    liveTrackCourseSharing, simpleSetupFeatureList, windDataAppSupport, httpRawResourceRequest, samd,
    sync2, navigationSync, realtimeSettings, handCalibrationImgDetect, toystoreMobile,
    featureCapabilitiesExchange, deepLinking, garminConnectServer, credentialsOauth2Support, genericCredentials,
    capability100, capability101, capability102, capability103, capability104,
    capability105, capability106, capability107, capability108, capability109,
    capability110, capability111, capability112, capability113, capability114,
    capability115, capability116, capability117, capability118, capability119,
    capability120, capability121, capability122, capability123, capability124,
    capability125, capability126, capability127, capability128
}

public struct BatteryStatus: Sendable, Codable, Hashable {
    public var percent: Int
    public var isCharging: Bool
    public init(percent: Int, isCharging: Bool) { self.percent = percent; self.isCharging = isCharging }
}

// MARK: - Health samples

public struct HeartRateSample: Sendable, Codable, Hashable {
    public var date: Date
    public var bpm: Int
    public init(date: Date, bpm: Int) { self.date = date; self.bpm = bpm }
}

/// Interval quantity (steps, active kcal, distance, floors, intensity minutes...).
public struct IntervalSample: Sendable, Codable, Hashable {
    public var start: Date
    public var end: Date
    public var value: Double
    public init(start: Date, end: Date, value: Double) { self.start = start; self.end = end; self.value = value }
}

/// Point quantity (stress 0-100, SpO2 %, respiration brpm, body battery 0-100, HRV ms, resting HR...).
public struct PointSample: Sendable, Codable, Hashable {
    public var date: Date
    public var value: Double
    public init(date: Date, value: Double) { self.date = date; self.value = value }
}

public enum SleepStage: String, Sendable, Codable, CaseIterable {
    case awake, light, deep, rem, unmeasurable
}

public struct SleepInterval: Sendable, Codable, Hashable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage
    public init(start: Date, end: Date, stage: SleepStage) { self.start = start; self.end = end; self.stage = stage }
}

public struct SleepSession: Sendable, Codable, Hashable {
    public var start: Date
    public var end: Date
    public var intervals: [SleepInterval]
    /// Garmin sleep score 0-100 when the watch provides it.
    public var score: Int?
    /// The components the overall score is made of, when the watch sends them.
    public var scoreBreakdown: SleepScoreBreakdown?
    public init(start: Date, end: Date, intervals: [SleepInterval], score: Int? = nil,
                scoreBreakdown: SleepScoreBreakdown? = nil) {
        self.start = start; self.end = end; self.intervals = intervals; self.score = score
        self.scoreBreakdown = scoreBreakdown
    }
}

/// The component scores of a sleep score, each 0-100, and the raw awakening count and stress during sleep.
public struct SleepScoreBreakdown: Sendable, Codable, Hashable {
    public var duration: Int?
    public var quality: Int?
    public var recovery: Int?
    public var deep: Int?
    public var light: Int?
    public var rem: Int?
    public var awakeTime: Int?
    public var awakenings: Int?
    public var interruptions: Int?
    public var restlessness: Int?
    public var combinedAwake: Int?
    public var awakeningsCount: Int?
    /// Average stress while asleep, 0-100.
    public var averageStress: Double?
    public init(duration: Int? = nil, quality: Int? = nil, recovery: Int? = nil, deep: Int? = nil, light: Int? = nil,
                rem: Int? = nil, awakeTime: Int? = nil, awakenings: Int? = nil, interruptions: Int? = nil,
                restlessness: Int? = nil, combinedAwake: Int? = nil, awakeningsCount: Int? = nil,
                averageStress: Double? = nil) {
        self.duration = duration; self.quality = quality; self.recovery = recovery; self.deep = deep
        self.light = light; self.rem = rem; self.awakeTime = awakeTime; self.awakenings = awakenings
        self.interruptions = interruptions; self.restlessness = restlessness; self.combinedAwake = combinedAwake
        self.awakeningsCount = awakeningsCount; self.averageStress = averageStress
    }
}

/// A sleep stream minute of a watch that does not stage sleep (FIT 274 rows, with the awake and unmeasurable
/// minutes from FIT 275). Raw minutes carry heart rate and movement for the app to classify.
public enum RawSleepMinuteKind: String, Sendable, Codable, CaseIterable {
    case raw, awake, unmeasurable
}

public struct RawSleepMinute: Sendable, Codable, Hashable {
    public var date: Date
    public var kind: RawSleepMinuteKind
    public var heartRate: Double?
    /// Movement count for the minute, zero when still.
    public var movement: Double?
    public init(date: Date, kind: RawSleepMinuteKind, heartRate: Double? = nil, movement: Double? = nil) {
        self.date = date; self.kind = kind; self.heartRate = heartRate; self.movement = movement
    }
}

/// A nap the watch recorded. Naps have no stages.
public struct Nap: Sendable, Codable, Hashable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

/// The watch's HRV status for a night (FIT 370): the weekly average, last night, and the baseline it compares to.
/// Values are RMSSD in ms.
public enum HRVStatus: String, Sendable, Codable, CaseIterable {
    case none, poor, low, unbalanced, balanced
}

public struct HRVStatusSample: Sendable, Codable, Hashable {
    public var date: Date
    public var weeklyAverage: Double?
    public var lastNightAverage: Double?
    public var lastNight5MinHigh: Double?
    public var baselineLowUpper: Double?
    public var baselineBalancedLower: Double?
    public var baselineBalancedUpper: Double?
    public var status: HRVStatus?
    public init(date: Date, weeklyAverage: Double? = nil, lastNightAverage: Double? = nil,
                lastNight5MinHigh: Double? = nil, baselineLowUpper: Double? = nil,
                baselineBalancedLower: Double? = nil, baselineBalancedUpper: Double? = nil, status: HRVStatus? = nil) {
        self.date = date; self.weeklyAverage = weeklyAverage; self.lastNightAverage = lastNightAverage
        self.lastNight5MinHigh = lastNight5MinHigh; self.baselineLowUpper = baselineLowUpper
        self.baselineBalancedLower = baselineBalancedLower; self.baselineBalancedUpper = baselineBalancedUpper
        self.status = status
    }
}

/// The watch's own training load (FIT 378): acute (7 day) and chronic (28 day) load.
public struct TrainingLoadSample: Sendable, Codable, Hashable {
    public var date: Date
    public var acute: Double?
    public var chronic: Double?
    public init(date: Date, acute: Double? = nil, chronic: Double? = nil) {
        self.date = date; self.acute = acute; self.chronic = chronic
    }
}

// MARK: - Activities

/// Subset of FIT `sport` (+ `sub_sport`) the app understands. rawValue = FIT sport number.
public enum Sport: Int, Sendable, Codable, CaseIterable {
    case generic = 0, running = 1, cycling = 2, transition = 3, fitnessEquipment = 4, swimming = 5
    case basketball = 6, soccer = 7, tennis = 8, americanFootball = 9, training = 10, walking = 11
    case crossCountrySkiing = 12, alpineSkiing = 13, snowboarding = 14, rowing = 15, mountaineering = 16
    case hiking = 17, multisport = 18, paddling = 19, flying = 20, eBiking = 21, motorcycling = 22
    case boating = 23, driving = 24, golf = 25, hangGliding = 26, horsebackRiding = 27, hunting = 28
    case fishing = 29, inlineSkating = 30, rockClimbing = 31, sailing = 32, iceSkating = 33, skyDiving = 34
    case snowshoeing = 35, snowmobiling = 36, standUpPaddleboarding = 37, surfing = 38, wakeboarding = 39
    case waterSkiing = 40, kayaking = 41, rafting = 42, windsurfing = 43, kitesurfing = 44, tactical = 45
    case jumpmaster = 46, boxing = 47, floorClimbing = 48, baseball = 49, diving = 53, hiit = 62
    case racket = 64, wheelchairPushWalk = 65, wheelchairPushRun = 66, meditation = 67, discGolf = 69
    case cricket = 71, rugby = 72, hockey = 73, lacrosse = 74, volleyball = 75, waterTubing = 76
    case wakesurfing = 77, mixedMartialArts = 80, snorkeling = 82, dance = 83, jumpRope = 84
}

public struct ActivityRecord: Sendable, Codable, Hashable {
    public var date: Date
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var heartRate: Int?
    /// m/s
    public var speed: Double?
    /// metres since start
    public var distance: Double?
    public var cadence: Int?
    public var power: Int?
    public var temperature: Double?
    public init(date: Date, latitude: Double? = nil, longitude: Double? = nil, altitude: Double? = nil,
                heartRate: Int? = nil, speed: Double? = nil, distance: Double? = nil, cadence: Int? = nil,
                power: Int? = nil, temperature: Double? = nil) {
        self.date = date; self.latitude = latitude; self.longitude = longitude; self.altitude = altitude
        self.heartRate = heartRate; self.speed = speed; self.distance = distance; self.cadence = cadence
        self.power = power; self.temperature = temperature
    }
}

public struct ActivityLap: Sendable, Codable, Hashable {
    public var start: Date
    public var end: Date
    public var distance: Double?
    public var calories: Double?
    public var averageHeartRate: Int?
    public init(start: Date, end: Date, distance: Double? = nil, calories: Double? = nil, averageHeartRate: Int? = nil) {
        self.start = start; self.end = end; self.distance = distance; self.calories = calories
        self.averageHeartRate = averageHeartRate
    }
}

public struct Activity: Sendable, Codable, Hashable, Identifiable {
    /// Stable id: "<unitNumber>-<garmin start seconds>" or file name based; set by the extractor.
    public var id: String
    public var sport: Sport
    public var subSport: Int?
    public var name: String?
    public var start: Date
    public var end: Date
    /// Moving/timer time in seconds.
    public var duration: TimeInterval
    public var distance: Double?
    public var activeCalories: Double?
    public var averageHeartRate: Int?
    public var maxHeartRate: Int?
    public var totalAscent: Double?
    public var totalDescent: Double?
    public var averageSpeed: Double?
    public var averageCadence: Int?
    public var averagePower: Int?
    public var trainingEffect: Double?
    public var laps: [ActivityLap]
    public var records: [ActivityRecord]
    public init(id: String, sport: Sport, subSport: Int? = nil, name: String? = nil, start: Date, end: Date,
                duration: TimeInterval, distance: Double? = nil, activeCalories: Double? = nil,
                averageHeartRate: Int? = nil, maxHeartRate: Int? = nil, totalAscent: Double? = nil,
                totalDescent: Double? = nil, averageSpeed: Double? = nil, averageCadence: Int? = nil,
                averagePower: Int? = nil, trainingEffect: Double? = nil, laps: [ActivityLap] = [],
                records: [ActivityRecord] = []) {
        self.id = id; self.sport = sport; self.subSport = subSport; self.name = name; self.start = start
        self.end = end; self.duration = duration; self.distance = distance; self.activeCalories = activeCalories
        self.averageHeartRate = averageHeartRate; self.maxHeartRate = maxHeartRate; self.totalAscent = totalAscent
        self.totalDescent = totalDescent; self.averageSpeed = averageSpeed; self.averageCadence = averageCadence
        self.averagePower = averagePower; self.trainingEffect = trainingEffect; self.laps = laps; self.records = records
    }
}

// MARK: - Batch

/// Everything extracted from one or more FIT files. HealthKit writer and UI consume this.
public struct HealthBatch: Sendable, Codable, Hashable {
    public var heartRate: [HeartRateSample] = []
    public var restingHeartRate: [PointSample] = []
    public var steps: [IntervalSample] = []
    public var activeEnergyKcal: [IntervalSample] = []
    public var restingEnergyKcal: [IntervalSample] = []
    /// metres
    public var distance: [IntervalSample] = []
    public var floorsClimbed: [IntervalSample] = []
    /// minutes (moderate + 2x vigorous already applied by the watch)
    public var intensityMinutes: [IntervalSample] = []
    public var stress: [PointSample] = []
    public var bodyBattery: [PointSample] = []
    /// 0...1 fraction
    public var spo2: [PointSample] = []
    /// breaths per minute
    public var respirationRate: [PointSample] = []
    /// RMSSD in ms
    public var hrv: [PointSample] = []
    public var sleep: [SleepSession] = []
    public var activities: [Activity] = []
    /// Minutes of the raw sleep stream of a watch that does not stage sleep (FIT 273/274).
    public var rawSleepMinutes: [RawSleepMinute] = []
    public var naps: [Nap] = []
    public var hrvStatus: [HRVStatusSample] = []
    /// Training readiness score 0-100.
    public var trainingReadiness: [PointSample] = []
    public var trainingLoad: [TrainingLoadSample] = []
    /// Minutes until the watch considers the body recovered from the last activity.
    public var recoveryTime: [PointSample] = []

    public init() {}

    /// Older histories were saved without the newer fields, so every array decodes as empty when it is missing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list<T: Decodable>(_ key: CodingKeys) throws -> [T] {
            try c.decodeIfPresent([T].self, forKey: key) ?? []
        }
        heartRate = try list(.heartRate)
        restingHeartRate = try list(.restingHeartRate)
        steps = try list(.steps)
        activeEnergyKcal = try list(.activeEnergyKcal)
        restingEnergyKcal = try list(.restingEnergyKcal)
        distance = try list(.distance)
        floorsClimbed = try list(.floorsClimbed)
        intensityMinutes = try list(.intensityMinutes)
        stress = try list(.stress)
        bodyBattery = try list(.bodyBattery)
        spo2 = try list(.spo2)
        respirationRate = try list(.respirationRate)
        hrv = try list(.hrv)
        sleep = try list(.sleep)
        activities = try list(.activities)
        rawSleepMinutes = try list(.rawSleepMinutes)
        naps = try list(.naps)
        hrvStatus = try list(.hrvStatus)
        trainingReadiness = try list(.trainingReadiness)
        trainingLoad = try list(.trainingLoad)
        recoveryTime = try list(.recoveryTime)
    }

    public mutating func merge(_ other: HealthBatch) {
        heartRate += other.heartRate; restingHeartRate += other.restingHeartRate; steps += other.steps
        activeEnergyKcal += other.activeEnergyKcal; restingEnergyKcal += other.restingEnergyKcal
        distance += other.distance; floorsClimbed += other.floorsClimbed; intensityMinutes += other.intensityMinutes
        stress += other.stress; bodyBattery += other.bodyBattery; spo2 += other.spo2
        respirationRate += other.respirationRate; hrv += other.hrv; sleep += other.sleep; activities += other.activities
        rawSleepMinutes += other.rawSleepMinutes; naps += other.naps; hrvStatus += other.hrvStatus
        trainingReadiness += other.trainingReadiness; trainingLoad += other.trainingLoad
        recoveryTime += other.recoveryTime
    }

    public var isEmpty: Bool { self == HealthBatch() }
}

// MARK: - Workouts pushed to the watch

public enum WorkoutDurationType: Sendable, Codable, Hashable {
    case open
    case time(seconds: Int)
    case distance(meters: Int)
    case calories(kcal: Int)
    case heartRateLessThan(bpm: Int)
    case heartRateGreaterThan(bpm: Int)
    case repeatUntilStepsComplete(fromStep: Int, count: Int)
    case reps(count: Int)
}

public enum WorkoutTarget: Sendable, Codable, Hashable {
    case none
    case heartRateZone(Int)
    case heartRateRange(low: Int, high: Int)
    case paceRange(lowSecondsPerKm: Int, highSecondsPerKm: Int)
    case cadenceRange(low: Int, high: Int)
    case powerRange(low: Int, high: Int)
}

public enum WorkoutIntensity: Int, Sendable, Codable, CaseIterable {
    case active = 0, rest = 1, warmup = 2, cooldown = 3, recovery = 4, interval = 5
}

/// An exercise from Garmin's strength catalog, identified on the watch by its category and name code.
public struct WorkoutExercise: Sendable, Codable, Hashable, Identifiable {
    /// The catalog id, such as "bench_press/barbell_bench_press".
    public var id: String
    public var name: String
    /// The FIT exercise_category number.
    public var category: Int
    /// The FIT exercise_name number within the category. Nil for the category's generic exercise.
    public var code: Int?
    public init(id: String, name: String, category: Int, code: Int?) {
        self.id = id; self.name = name; self.category = category; self.code = code
    }
}

public struct WorkoutStep: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String?
    public var intensity: WorkoutIntensity
    public var duration: WorkoutDurationType
    public var target: WorkoutTarget
    public var notes: String?
    /// The strength exercise the step is for.
    public var exercise: WorkoutExercise?
    /// The load of a strength step in kilograms.
    public var weightKg: Double?
    public init(id: UUID = UUID(), name: String? = nil, intensity: WorkoutIntensity, duration: WorkoutDurationType,
                target: WorkoutTarget = .none, notes: String? = nil, exercise: WorkoutExercise? = nil,
                weightKg: Double? = nil) {
        self.id = id; self.name = name; self.intensity = intensity; self.duration = duration
        self.target = target; self.notes = notes; self.exercise = exercise; self.weightKg = weightKg
    }
}

public struct WorkoutPlan: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var sport: Sport
    /// The FIT sub_sport number, such as 20 for strength training. Nil for the sport's default.
    public var subSport: Int?
    public var steps: [WorkoutStep]
    public init(id: UUID = UUID(), name: String, sport: Sport, subSport: Int? = nil, steps: [WorkoutStep]) {
        self.id = id; self.name = name; self.sport = sport; self.subSport = subSport; self.steps = steps
    }
}

// MARK: - Phone -> watch payloads

public struct WeatherForecastDay: Sendable, Codable, Hashable {
    public var date: Date
    public var lowCelsius: Double
    public var highCelsius: Double
    public var condition: WeatherCondition
    public var precipitationChance: Int
    public init(date: Date, lowCelsius: Double, highCelsius: Double, condition: WeatherCondition, precipitationChance: Int) {
        self.date = date; self.lowCelsius = lowCelsius; self.highCelsius = highCelsius
        self.condition = condition; self.precipitationChance = precipitationChance
    }
}

public struct WeatherForecastHour: Sendable, Codable, Hashable {
    public var date: Date
    public var temperatureCelsius: Double
    public var condition: WeatherCondition
    public var precipitationChance: Int
    public init(date: Date, temperatureCelsius: Double, condition: WeatherCondition, precipitationChance: Int) {
        self.date = date; self.temperatureCelsius = temperatureCelsius; self.condition = condition
        self.precipitationChance = precipitationChance
    }
}

public enum WeatherCondition: String, Sendable, Codable, CaseIterable {
    case clear, partlyCloudy, mostlyCloudy, cloudy, rain, lightRain, heavyRain, snow, lightSnow, heavySnow
    case sleet, thunderstorm, fog, haze, windy, hail, unknown
}

public struct WeatherReport: Sendable, Codable, Hashable {
    public var date: Date
    public var locationName: String
    public var latitude: Double
    public var longitude: Double
    public var temperatureCelsius: Double
    public var feelsLikeCelsius: Double
    public var lowCelsius: Double
    public var highCelsius: Double
    public var condition: WeatherCondition
    public var humidity: Int
    public var windSpeedMps: Double
    public var windDirectionDegrees: Int
    public var precipitationChance: Int
    public var uvIndex: Double?
    public var airQualityIndex: Int?
    public var hourly: [WeatherForecastHour]
    public var daily: [WeatherForecastDay]
    public init(date: Date, locationName: String, latitude: Double, longitude: Double, temperatureCelsius: Double,
                feelsLikeCelsius: Double, lowCelsius: Double, highCelsius: Double, condition: WeatherCondition,
                humidity: Int, windSpeedMps: Double, windDirectionDegrees: Int, precipitationChance: Int,
                uvIndex: Double? = nil, airQualityIndex: Int? = nil, hourly: [WeatherForecastHour] = [],
                daily: [WeatherForecastDay] = []) {
        self.date = date; self.locationName = locationName; self.latitude = latitude; self.longitude = longitude
        self.temperatureCelsius = temperatureCelsius; self.feelsLikeCelsius = feelsLikeCelsius
        self.lowCelsius = lowCelsius; self.highCelsius = highCelsius; self.condition = condition
        self.humidity = humidity; self.windSpeedMps = windSpeedMps; self.windDirectionDegrees = windDirectionDegrees
        self.precipitationChance = precipitationChance; self.uvIndex = uvIndex; self.airQualityIndex = airQualityIndex
        self.hourly = hourly; self.daily = daily
    }
}

public struct CalendarEvent: Sendable, Codable, Hashable {
    public var id: String
    public var title: String
    public var location: String?
    public var notes: String?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public init(id: String, title: String, location: String? = nil, notes: String? = nil, start: Date, end: Date, isAllDay: Bool) {
        self.id = id; self.title = title; self.location = location; self.notes = notes
        self.start = start; self.end = end; self.isAllDay = isAllDay
    }
}

/// Notification categories the watch can show an icon for. The raw values are Garmin's category bytes.
public enum PhoneNotificationCategory: UInt8, Sendable, Codable, Hashable, CaseIterable {
    case other, incomingCall, missedCall, voicemail, social, schedule, email, news
    case healthAndFitness, businessAndFinance, location, entertainment, sms
}

/// A button the watch shows under a phone notification. A negative action dismisses the notification on the watch;
/// a positive one reports the choice back to the app.
public struct PhoneNotificationAction: Sendable, Codable, Hashable {
    public var title: String
    public var isNegative: Bool
    public init(title: String, isNegative: Bool = false) {
        self.title = title; self.isNegative = isNegative
    }
}

/// A notification the app itself pushes over GFDI (in addition to iOS ANCS which the watch reads directly).
public struct PhoneNotification: Sendable, Codable, Hashable {
    public var id: Int
    public var appIdentifier: String
    public var title: String
    public var subtitle: String?
    public var body: String
    public var date: Date
    public var category: PhoneNotificationCategory
    /// At most five positive actions, which the watch numbers 1 to 5, and any number of negative ones.
    public var actions: [PhoneNotificationAction]
    public init(id: Int, appIdentifier: String, title: String, subtitle: String? = nil, body: String, date: Date,
                category: PhoneNotificationCategory = .other, actions: [PhoneNotificationAction] = []) {
        self.id = id; self.appIdentifier = appIdentifier; self.title = title; self.subtitle = subtitle
        self.body = body; self.date = date; self.category = category; self.actions = actions
    }
}

public struct UserProfile: Sendable, Codable, Hashable {
    public enum Gender: String, Sendable, Codable { case female, male }
    public var birthDate: Date?
    public var gender: Gender?
    public var heightCm: Double?
    public var weightKg: Double?
    public var restingHeartRate: Int?
    public var maxHeartRate: Int?
    public var usesMetricUnits: Bool
    public var uses24HourTime: Bool
    public var sleepTime: DateComponents?
    public var wakeTime: DateComponents?
    public init(birthDate: Date? = nil, gender: Gender? = nil, heightCm: Double? = nil, weightKg: Double? = nil,
                restingHeartRate: Int? = nil, maxHeartRate: Int? = nil, usesMetricUnits: Bool = true,
                uses24HourTime: Bool = true, sleepTime: DateComponents? = nil, wakeTime: DateComponents? = nil) {
        self.birthDate = birthDate; self.gender = gender; self.heightCm = heightCm; self.weightKg = weightKg
        self.restingHeartRate = restingHeartRate; self.maxHeartRate = maxHeartRate
        self.usesMetricUnits = usesMetricUnits; self.uses24HourTime = uses24HourTime
        self.sleepTime = sleepTime; self.wakeTime = wakeTime
    }
}
