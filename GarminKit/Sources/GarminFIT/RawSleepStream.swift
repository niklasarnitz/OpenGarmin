import Foundation
import GarminModels

/// Places the minutes of a sleep stream that carries no timestamp per minute. Ported from Gadgetbridge's
/// `RawSleepStream` (#4048), which is documented there.
///
/// After the sleep data info (FIT 273), every raw row (FIT 274) and every sleep level row (FIT 275) takes the next
/// slot, one sample length apart. Raw rows have no timestamp of their own, so their order in the file places them.
/// Awake and unmeasurable levels become minutes of their own; the other levels only take a slot.
struct RawSleepStream {
    private static let defaultSampleSeconds: Int64 = 60
    private static let maxSampleSeconds: Int64 = 3600

    private var startSeconds: Int64?
    private var stepSeconds = defaultSampleSeconds
    private var slot: Int64 = 0

    /// Raw rows seen, including any before the sleep data info.
    private(set) var rawCount = 0
    private(set) var minutes: [RawSleepMinute] = []

    mutating func onInfo(timestamp: Int64?, sampleLength: Int64?) {
        guard let timestamp else { return }
        startSeconds = timestamp
        if let sampleLength, (1...Self.maxSampleSeconds).contains(sampleLength) {
            stepSeconds = sampleLength
        } else {
            stepSeconds = Self.defaultSampleSeconds
        }
        slot = 0
    }

    mutating func onRaw(heartRate: Double?, movement: Double?) {
        rawCount += 1
        guard let startSeconds else { return }
        minutes.append(RawSleepMinute(date: slotDate(startSeconds), kind: .raw, heartRate: heartRate,
                                      movement: movement ?? 0))
        slot += 1
    }

    /// `level` is the FIT sleep level: 0 unmeasurable, 1 awake, 2 light, 3 deep, 4 REM.
    mutating func onLevel(timestamp: Int64?, level: Int64) {
        guard let startSeconds else { return }
        let kind: RawSleepMinuteKind? = switch level {
        case 1: .awake
        case 0: .unmeasurable
        default: nil
        }
        if let kind {
            let time = timestamp.map { date($0) } ?? slotDate(startSeconds)
            minutes.append(RawSleepMinute(date: time, kind: kind))
        }
        slot += 1
    }

    private func slotDate(_ startSeconds: Int64) -> Date {
        date(startSeconds + slot * stepSeconds)
    }
}

/// The 10 little-endian half-precision features of a raw sleep row (FIT 274). Heart rate is feature 9 and movement
/// is feature 8. Ported from Gadgetbridge's `FitSleepDataRaw`.
enum RawSleepRow {
    static let featureCount = 10
    static let movementIndex = 8
    static let heartRateIndex = 9
    static let heartRateRange: ClosedRange<Double> = 25...250

    /// The features of a row, or nil when the row does not hold exactly ten of them.
    static func features(_ bytes: [UInt8]) -> [Double]? {
        guard bytes.count == featureCount * 2 else { return nil }
        return (0..<featureCount).map { index in
            halfPrecision(UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)
        }
    }

    static func heartRate(_ features: [Double]?) -> Double? {
        guard let features else { return nil }
        let heartRate = features[heartRateIndex]
        return heartRateRange.contains(heartRate) ? heartRate : nil
    }

    static func movement(_ features: [Double]?) -> Double? {
        guard let features else { return nil }
        let movement = features[movementIndex]
        return movement.isFinite && movement >= 0 ? movement : nil
    }

    /// IEEE 754 half precision. NaN has no value.
    static func halfPrecision(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int(bits >> 10) & 0x1F
        let mantissa = Double(bits & 0x3FF)
        switch exponent {
        case 0: return sign * mantissa * pow(2, -24)
        case 0x1F: return mantissa == 0 ? sign * .infinity : .nan
        default: return sign * (1 + mantissa / 1024) * pow(2, Double(exponent - 15))
        }
    }
}
