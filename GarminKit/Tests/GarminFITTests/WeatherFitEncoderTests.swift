import Foundation
import Testing
import GarminFIT
import GarminModels

@Test func encodesCurrentWeatherLikeGadgetbridge() throws {
    let report = WeatherReport(
        date: Date(timeIntervalSince1970: 1_800_000_000), locationName: "Berlin",
        latitude: 52.52, longitude: 13.405,
        temperatureCelsius: 21, feelsLikeCelsius: 20, lowCelsius: 12, highCelsius: 24,
        condition: .clear, humidity: 40, windSpeedMps: 3, windDirectionDegrees: 270, precipitationChance: 10
    )

    let payload = WeatherFitEncoder.encode(report, timeZone: TimeZone(identifier: "UTC")!)

    // Definition for local type 0: reserved 0, big endian, global 128 (weather_conditions), 17 fields.
    // The first field is weather_report (0), an enum of one byte.
    // Local type 1 follows for today's daily forecast, since there are no hourly messages.
    #expect(Array(payload.definitions.prefix(9)) == [0x40, 0x00, 0x01, 0x00, 0x80, 0x11, 0x00, 0x01, 0x00])

    // Data message for local type 0, in definition order: header, weather_report 0, timestamp and
    // observed_at (Garmin seconds, big endian: 1_800_000_000 - 631_065_600 = 0x45AC8600), temperature 21,
    // low 12, high 24, condition 0 (clear), wind direction 270 (uint16), precipitation 10,
    // wind speed 3 m/s as 3000 (uint16, m/s times 1000).
    let expected: [UInt8] = [
        0x00,
        0x00,
        0x45, 0xAC, 0x86, 0x00,
        0x45, 0xAC, 0x86, 0x00,
        0x15,
        0x0C,
        0x18,
        0x00,
        0x01, 0x0E,
        0x0A,
        0x0B, 0xB8,
    ]
    #expect(Array(payload.data.prefix(expected.count)) == expected)
}
