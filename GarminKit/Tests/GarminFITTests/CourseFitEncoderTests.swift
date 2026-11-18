import Foundation
import Testing
import GarminFIT

/// Three points along the equator and one meridian: 0.001° east, then 0.001° north. The second point is a left turn.
/// Altitudes go 10, 15, 12 m, so the ascent is 5 m and the descent 3 m.
private let loopGPX = """
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Loop</name>
    <trkseg>
      <trkpt lat="0" lon="0"><ele>10</ele></trkpt>
      <trkpt lat="0" lon="0.001"><ele>15</ele></trkpt>
      <trkpt lat="0.001" lon="0.001"><ele>12</ele></trkpt>
    </trkseg>
  </trk>
</gpx>
"""

private let start = Date(timeIntervalSince1970: 1_800_000_000)
/// The start in watch time, which the timestamps count from.
private let startSeconds: Int64 = 1_168_934_400

@Test func gpxTrackReadsEveryPointOfTheFirstTrack() throws {
    let points = try GPXTrack.points(in: Data(loopGPX.utf8))

    #expect(points.count == 3)
    #expect(points[1] == GPXTrackPoint(latitude: 0, longitude: 0.001, altitude: 15))
    #expect(points[2].altitude == 12)
}

@Test func gpxRejectsWhatIsNotAGPXFileOrHasNoPoints() throws {
    #expect(throws: GPXError.notGPX) { try GPXTrack.points(in: Data("not xml".utf8)) }
    let empty = "<gpx><trk><trkseg></trkseg></trk></gpx>"
    #expect(throws: GPXError.noTrackPoints) { try GPXTrack.points(in: Data(empty.utf8)) }
}

@Test func courseFileHasTheFileIDCourseAndLapOfTheTrack() throws {
    let points = try GPXTrack.points(in: Data(loopGPX.utf8))
    let file = try FitDecoder.decode(CourseFitEncoder.encode(points, name: "Loop", start: start, includeTurns: false))

    // file_id: type 6 is a course.
    #expect(file.messages(0).first?[0]?.int == 6)
    let course = try #require(file.messages(31).first)
    #expect(course[5]?.string == "Loop")
    #expect(course[4]?.int == 0)

    // Lap: the start and end positions in semicircles (0.001° is 11 930 semicircles), the distance in centimetres
    // (two steps of 111.195 m, 22 239 cm), the elapsed time in milliseconds (158 s), and the climb and descent in metres.
    let lap = try #require(file.messages(19).first)
    #expect(lap[3]?.int == 0)
    #expect(lap[6]?.int == 11_930)
    #expect(lap[9]?.int == 22_239)
    #expect(lap[7]?.int == 158_000)
    #expect(lap[21]?.int == 5)
    #expect(lap[22]?.int == 3)
}

@Test func courseRecordsAreTimedAtOneAndAHalfMetresPerSecond() throws {
    let points = try GPXTrack.points(in: Data(loopGPX.utf8))
    let file = try FitDecoder.decode(CourseFitEncoder.encode(points, name: "Loop", start: start, includeTurns: false))

    // Each step of 111.195 m takes 79 s at 1.4 m/s, so the records are 0, 79 and 158 s after the start.
    let records = file.messages(20)
    #expect(records.count == 3)
    #expect(records.map { $0[253]?.int } == [startSeconds, startSeconds + 79, startSeconds + 158])
    // Positions in semicircles, altitude with its 500 m offset and scale 5, distance in centimetres.
    #expect(records[1][0]?.int == 0)
    #expect(records[1][1]?.int == 11_930)
    #expect(records[2][0]?.int == 11_930)
    #expect(records.map { $0[2]?.int } == [2_550, 2_575, 2_560])
    #expect(records.map { $0[5]?.int } == [0, 11_119, 22_239])
}

@Test func courseEndsWithTheStopEventAfterTheRecords() throws {
    let points = try GPXTrack.points(in: Data(loopGPX.utf8))
    let file = try FitDecoder.decode(CourseFitEncoder.encode(points, name: "Loop", start: start, includeTurns: false))

    // Event type 0 starts the timer and 9 (stop, disable all) ends it. Gadgetbridge puts the stop last, or some watches freeze.
    let events = file.messages(21)
    #expect(events.map { $0[1]?.int } == [0, 9])
    #expect(file.messages.last?.globalNumber == 21)
    #expect(file.messages(32).isEmpty)
}

@Test func leftTurnBecomesALeftCoursePointAtThePointBeforeIt() throws {
    let points = try GPXTrack.points(in: Data(loopGPX.utf8))
    let file = try FitDecoder.decode(CourseFitEncoder.encode(points, name: "Loop", start: start, includeTurns: true))

    // Heading east, then north: a turn of 270° in bearing, which is a left turn (type 6). It sits on the second point.
    let coursePoints = file.messages(32)
    #expect(coursePoints.count == 1)
    let turn = try #require(coursePoints.first)
    #expect(turn[5]?.int == 6)
    #expect(turn[1]?.int == startSeconds + 79)
    #expect(turn[4]?.int == 11_119)
    #expect(turn[254]?.int == 0)
}
