import Foundation
import GarminCore
import GarminModels

/// The weather of one report as GFDI sends it: every definition message, then every data message.
public struct WeatherFitPayload: Sendable, Hashable {
    public var definitions: Data
    public var data: Data
    public init(definitions: Data, data: Data) {
        self.definitions = definitions
        self.data = data
    }
}

/// Encodes a `WeatherReport` as FIT `weather_conditions` messages (global 128), big endian, laid out as
/// Gadgetbridge's `GarminSupport.encodeWeather`: one current message, up to 12 hourly forecasts and up to
/// 4 daily forecasts. Each layout has its own local message type, and every field Gadgetbridge sends is
/// present in the layout, with the invalid value where the report has no data.
///
/// Deliberate difference: each daily forecast carries its own date as its timestamp. Gadgetbridge stamps
/// all of them with the current report's time.
public enum WeatherFitEncoder {
    private static let conditionsGlobal: UInt16 = 128
    private static let maxHourly = 12
    private static let maxDaily = 4
    /// Degrees per semicircle, as in Gadgetbridge's `GarminUtils`.
    private static let semicircleDegrees = 180.0 / 2_147_483_648.0

    /// - Parameter timeZone: the zone the weekday of each day is taken in.
    public static func encode(_ report: WeatherReport, timeZone: TimeZone = .current) -> WeatherFitPayload {
        let hourly = report.hourly.prefix(maxHourly)
        // Without hourly messages, Gadgetbridge's next free local type is 1, and the daily messages take it.
        let dailyType: UInt8 = hourly.isEmpty ? 1 : 2

        var entries: [(localType: UInt8, fields: [FitEncodeField])] = [(0, currentFields(report))]
        for hour in hourly {
            entries.append((1, hourlyFields(hour)))
        }
        entries.append((dailyType, dailyFields(
            report.date, timeZone: timeZone, low: report.lowCelsius, high: report.highCelsius,
            condition: report.condition, precipitation: report.precipitationChance,
            airQuality: report.airQualityIndex, humidity: report.humidity,
            windSpeedMps: report.windSpeedMps, windDirection: report.windDirectionDegrees,
            uvIndex: report.uvIndex
        )))
        for day in report.daily.prefix(maxDaily) {
            entries.append((dailyType, dailyFields(
                day.date, timeZone: timeZone, low: day.lowCelsius, high: day.highCelsius,
                condition: day.condition, precipitation: day.precipitationChance
            )))
        }

        var definitions = Data()
        var defined = Set<UInt8>()
        for entry in entries where defined.insert(entry.localType).inserted {
            definitions += FitEncoder.definitionMessage(localType: entry.localType, message(entry.fields), bigEndian: true)
        }
        var data = Data()
        for entry in entries {
            data += FitEncoder.dataMessage(localType: entry.localType, message(entry.fields), bigEndian: true)
        }
        return WeatherFitPayload(definitions: definitions, data: data)
    }

    private static func message(_ fields: [FitEncodeField]) -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: conditionsGlobal, fields: fields)
    }

    private static func currentFields(_ report: WeatherReport) -> [FitEncodeField] {
        [
            field(0, .enumeration, 0),
            garminTime(253, report.date),
            garminTime(9, report.date),
            field(1, .sint8, report.temperatureCelsius),
            field(14, .sint8, report.lowCelsius),
            field(13, .sint8, report.highCelsius),
            field(2, .enumeration, conditionCode(report.condition)),
            field(3, .uint16, windDirectionValue(report.windDirectionDegrees)),
            field(5, .uint8, percentValue(report.precipitationChance)),
            field(4, .uint16, windSpeedValue(report.windSpeedMps)),
            field(6, .sint8, report.feelsLikeCelsius),
            field(7, .uint8, percentValue(report.humidity)),
            field(10, .sint32, report.latitude / semicircleDegrees),
            field(11, .sint32, report.longitude / semicircleDegrees),
            field(17, .enumeration, aqiLevel(report.airQualityIndex)),
            field(15, .sint8, nil),
            FitEncodeField(8, .string, .string(report.locationName)),
        ]
    }

    private static func hourlyFields(_ hour: WeatherForecastHour) -> [FitEncodeField] {
        [
            field(0, .enumeration, 1),
            garminTime(253, hour.date),
            field(1, .sint8, hour.temperatureCelsius),
            field(2, .enumeration, conditionCode(hour.condition)),
            field(3, .uint16, nil),
            field(4, .uint16, nil),
            field(5, .uint8, percentValue(hour.precipitationChance)),
            // Gadgetbridge sends the air temperature as the feels-like temperature too.
            field(6, .sint8, hour.temperatureCelsius),
            field(7, .uint8, nil),
            field(15, .sint8, nil),
            field(16, .float32, nil),
            field(17, .enumeration, nil),
            field(18, .uint32, nil),
        ]
    }

    /// The daily layout shared by today's message and the daily forecasts.
    private static func dailyFields(
        _ date: Date, timeZone: TimeZone,
        low: Double, high: Double, condition: WeatherCondition, precipitation: Int,
        airQuality: Int? = nil, humidity: Int? = nil, windSpeedMps: Double? = nil,
        windDirection: Int? = nil, uvIndex: Double? = nil
    ) -> [FitEncodeField] {
        [
            field(0, .enumeration, 2),
            garminTime(253, date),
            field(14, .sint8, low),
            field(13, .sint8, high),
            field(2, .enumeration, conditionCode(condition)),
            field(5, .uint8, percentValue(precipitation)),
            field(12, .enumeration, dayOfWeek(date, timeZone)),
            field(17, .enumeration, aqiLevel(airQuality)),
            field(7, .uint8, humidity.map(percentValue)),
            field(4, .uint16, windSpeedMps.map(windSpeedValue)),
            field(3, .uint16, windDirection.map(windDirectionValue)),
            field(16, .float32, uvIndex.map(uvValue)),
            field(18, .uint32, nil),
        ]
    }

    private static func field(_ number: UInt8, _ baseType: FitBaseType, _ value: Double?) -> FitEncodeField {
        FitEncodeField(number, baseType, value.map { FitValue.double($0) })
    }

    /// A date field in Garmin seconds.
    private static func garminTime(_ number: UInt8, _ date: Date) -> FitEncodeField {
        FitEncodeField(number, .uint32, .int(Int64(GarminTime.garminSeconds(from: date))))
    }

    /// `weather_condition` values, as Gadgetbridge maps them. Unknown conditions are sent as invalid.
    private static func conditionCode(_ condition: WeatherCondition) -> Double? {
        switch condition {
        case .clear: 0
        case .partlyCloudy: 1
        case .mostlyCloudy: 2
        case .rain: 3
        case .snow: 4
        case .windy: 5
        case .thunderstorm: 6
        case .sleet: 7
        case .fog: 8
        case .haze: 11
        case .hail: 12
        case .lightRain: 16
        case .heavyRain: 17
        case .lightSnow: 18
        case .heavySnow: 19
        case .cloudy: 22
        case .unknown: nil
        }
    }

    /// `weather_aqi` for an air quality index, with the thresholds of Gadgetbridge's `FieldDefinitionWeatherAqi`.
    private static func aqiLevel(_ index: Int?) -> Double? {
        guard let index, index != -1 else { return nil }
        switch index {
        case ..<20: return 0
        case ..<50: return 1
        case ..<100: return 2
        case ..<150: return 3
        case ..<250: return 4
        default: return 5
        }
    }

    /// Wind speed in m/s × 1000, capped at 65.53 m/s as in Gadgetbridge.
    private static func windSpeedValue(_ mps: Double) -> Double {
        min(mps, 65.53) * 1000
    }

    private static func windDirectionValue(_ degrees: Int) -> Double {
        Double(((degrees % 360) + 360) % 360)
    }

    private static func percentValue(_ percent: Int) -> Double {
        Double(min(max(percent, 0), 100))
    }

    /// UV index, capped at 10 as the FIT scale is 0 to 10.
    private static func uvValue(_ index: Double) -> Double {
        min(index, 10)
    }

    /// `day_of_week`: Sunday is 0, Monday 1, and so on.
    private static func dayOfWeek(_ date: Date, _ timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Double(calendar.component(.weekday, from: date) - 1)
    }
}
