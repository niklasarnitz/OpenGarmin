import Foundation
import GarminCore

/// Encodes a GPX track as a FIT course (file type 6), laid out as Gadgetbridge's `GpxRouteFileConverter`: file_id,
/// file_creator, course, lap, a start event, one record per point, a stop event, then a course point per turn.
/// The watch plays the course back by distance, so the timestamps follow Gadgetbridge's fixed 1.4 m/s.
public enum CourseFitEncoder {
    /// Speed in metres per second that sets the time between two points.
    public static let speed = 1.4

    /// - Parameters:
    ///   - start: the course's start time, which the timestamps count from.
    ///   - includeTurns: whether to add a course point for each turn the track makes.
    public static func encode(_ points: [GPXTrackPoint], name: String, start: Date, includeTurns: Bool) -> Data {
        let timestamp = Int64(GarminTime.garminSeconds(from: start))
        var running = timestamp
        var total = 0.0
        var ascent = 0.0
        var descent = 0.0
        var distances: [Double] = []
        var times: [Int64] = []
        var records: [FitEncodeMessage] = []

        var previous = points[0]
        for point in points {
            let step = distance(previous, point)
            total += step
            if let change = altitudeChange(from: previous, to: point) {
                ascent += max(0, change)
                descent += max(0, -change)
            }
            running += Int64(step / speed)
            distances.append(total)
            times.append(running)
            records.append(record(point, timestamp: running, distance: total))
            previous = point
        }

        var messages = [
            fileId(timestamp), fileCreator(), course(name: name),
            lap(points, timestamp: timestamp, elapsed: running - timestamp, distance: total, ascent: ascent, descent: descent),
            event(timestamp, type: 0),
        ]
        messages += records
        messages.append(event(running, type: 9)) // Stop must be at the end, or some watches will freeze.
        if includeTurns {
            for (index, turn) in turns(of: points).enumerated() {
                messages.append(coursePoint(points[turn.index], timestamp: times[turn.index],
                                            distance: distances[turn.index], type: turn.turn.coursePointType,
                                            messageIndex: index))
            }
        }
        return FitEncoder.encodeFile(messages)
    }

    // MARK: - Messages

    private static func fileId(_ timestamp: Int64) -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: 0, fields: [
            field(0, .enumeration, 6), // course
            field(1, .uint16, 1), // Garmin
            field(2, .uint16, 65534),
            field(3, .uint32z, 1),
            field(4, .uint32, timestamp),
            field(5, .uint16, 1),
            FitEncodeField(8, .string, .string("OpenGarmin")),
        ])
    }

    private static func fileCreator() -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: 49, fields: [field(0, .uint16, 1)])
    }

    private static func course(name: String) -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: 31, fields: [
            field(4, .enumeration, 0), // generic sport
            FitEncodeField(5, .string, .string(name)),
        ])
    }

    private static func lap(_ points: [GPXTrackPoint], timestamp: Int64, elapsed: Int64, distance: Double,
                            ascent: Double, descent: Double) -> FitEncodeMessage {
        let first = points[0]
        let last = points[points.count - 1]
        return FitEncodeMessage(globalNumber: 19, fields: [
            field(253, .uint32, timestamp),
            field(2, .uint32, timestamp),
            field(3, .sint32, semicircles(first.latitude)),
            field(4, .sint32, semicircles(first.longitude)),
            field(5, .sint32, semicircles(last.latitude)),
            field(6, .sint32, semicircles(last.longitude)),
            field(7, .uint32, elapsed * 1000),
            field(8, .uint32, elapsed * 1000),
            field(9, .uint32, centimetres(distance)),
            field(21, .uint16, Int64(ascent.rounded())),
            field(22, .uint16, Int64(descent.rounded())),
            field(25, .enumeration, 0),
            field(254, .uint16, 0),
        ])
    }

    private static func event(_ timestamp: Int64, type: Int64) -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: 21, fields: [
            field(253, .uint32, timestamp),
            field(0, .enumeration, 0), // timer
            field(1, .enumeration, type),
            field(4, .uint8, 0),
        ])
    }

    private static func record(_ point: GPXTrackPoint, timestamp: Int64, distance: Double) -> FitEncodeMessage {
        var fields = [
            field(253, .uint32, timestamp),
            field(0, .sint32, semicircles(point.latitude)),
            field(1, .sint32, semicircles(point.longitude)),
        ]
        if let altitude = point.altitude {
            // Altitude is stored with an offset of 500 m and a scale of 5.
            fields.append(field(2, .uint16, Int64(((altitude + 500) * 5).rounded())))
        }
        fields.append(field(5, .uint32, centimetres(distance)))
        return FitEncodeMessage(globalNumber: 20, fields: fields)
    }

    private static func coursePoint(_ point: GPXTrackPoint, timestamp: Int64, distance: Double, type: Int64,
                                    messageIndex: Int) -> FitEncodeMessage {
        FitEncodeMessage(globalNumber: 32, fields: [
            field(1, .uint32, timestamp),
            field(2, .sint32, semicircles(point.latitude)),
            field(3, .sint32, semicircles(point.longitude)),
            field(4, .uint32, centimetres(distance)),
            field(5, .enumeration, type),
            field(254, .uint16, Int64(messageIndex)),
        ])
    }

    private static func field(_ number: UInt8, _ baseType: FitBaseType, _ value: Int64) -> FitEncodeField {
        FitEncodeField(number, baseType, .int(value))
    }

    /// Degrees as FIT semicircles, rounded as Gadgetbridge rounds them.
    static func semicircles(_ degrees: Double) -> Int64 {
        Int64((degrees * (pow(2, 31) / 180)).rounded())
    }

    private static func centimetres(_ metres: Double) -> Int64 {
        Int64((metres * 100).rounded())
    }

    // MARK: - Turns

    /// Gadgetbridge's turn angles, in degrees of change in bearing.
    private enum Turn {
        case slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn

        /// The FIT course point type: left 6, right 7, straight 8, slight left 19, sharp left 20, slight right 21,
        /// sharp right 22, u-turn 23.
        var coursePointType: Int64 {
            switch self {
            case .slightLeft: 19
            case .left: 6
            case .sharpLeft: 20
            case .slightRight: 21
            case .right: 7
            case .sharpRight: 22
            case .uTurn: 23
            }
        }
    }

    /// The turns of a track, as Gadgetbridge's `GpxTurnDetector` finds them: a turn is recorded at the point before the
    /// change of bearing, once the track has moved on from it.
    private static func turns(of points: [GPXTrackPoint]) -> [(index: Int, turn: Turn)] {
        var distances = [Double](repeating: 0, count: points.count)
        for index in points.indices.dropFirst() {
            distances[index] = distances[index - 1] + distance(points[index - 1], points[index])
        }

        var turns: [(index: Int, turn: Turn)] = []
        var previousPoint = -1
        var turnPoint = -1
        var previousBearing = Double.nan
        for point in points.indices {
            if previousPoint >= 0, distances[point] - distances[previousPoint] > 5 {
                if turnPoint < 0 { turnPoint = previousPoint }
                let turnDistance = distances[point] - distances[turnPoint]
                let heading = floor(bearing(points[turnPoint], points[point]) + 0.5)
                let angle = (heading - previousBearing + 360).truncatingRemainder(dividingBy: 360)
                let isTurning = angle >= 10 && angle <= 350 && turnDistance < 25
                if !isTurning {
                    if let turn = turn(angle) { turns.append((turnPoint, turn)) }
                    previousBearing = heading
                    turnPoint = -1
                }
            }
            previousPoint = point
        }
        return turns
    }

    private static func turn(_ angle: Double) -> Turn? {
        guard angle >= 30, angle <= 330 else { return nil }
        if angle < 60 { return .slightRight }
        if angle < 120 { return .right }
        if angle < 150 { return .sharpRight }
        if angle <= 210 { return .uTurn }
        if angle <= 240 { return .sharpLeft }
        if angle <= 300 { return .left }
        return .slightLeft
    }

    // MARK: - Geometry

    private static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres.
    static func distance(_ a: GPXTrackPoint, _ b: GPXTrackPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing in degrees, clockwise from north, in [0, 360).
    private static func bearing(_ a: GPXTrackPoint, _ b: GPXTrackPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func altitudeChange(from a: GPXTrackPoint, to b: GPXTrackPoint) -> Double? {
        guard let from = a.altitude, let to = b.altitude else { return nil }
        return to - from
    }
}
