import Foundation
import Testing
import GarminModels
@testable import GarminExport

@Suite struct GPXWriterTests {
    @Test func writesTrackPointsWithExtensionsAndSkipsRecordsWithoutPosition() {
        let base = Date(timeIntervalSince1970: 1_000_000_000) // 2001-09-09T01:46:40Z
        let activity = Activity(
            id: "1-1000000000", sport: .running, name: "Lunch & <Run>",
            start: base, end: base.addingTimeInterval(3), duration: 3,
            records: [
                ActivityRecord(date: base, latitude: 52.52, longitude: 13.405, altitude: 34.5),
                ActivityRecord(date: base.addingTimeInterval(1), latitude: 52.5201, longitude: 13.4051,
                               heartRate: 141, cadence: 84),
                ActivityRecord(date: base.addingTimeInterval(2), heartRate: 150),
            ])

        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenGarmin" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <metadata>
            <name>Lunch &amp; &lt;Run&gt;</name>
            <time>2001-09-09T01:46:40Z</time>
          </metadata>
          <trk>
            <name>Lunch &amp; &lt;Run&gt;</name>
            <trkseg>
              <trkpt lat="52.5200000" lon="13.4050000">
                <ele>34.5</ele>
                <time>2001-09-09T01:46:40Z</time>
              </trkpt>
              <trkpt lat="52.5201000" lon="13.4051000">
                <time>2001-09-09T01:46:41Z</time>
                <extensions>
                  <gpxtpx:TrackPointExtension>
                    <gpxtpx:hr>141</gpxtpx:hr>
                    <gpxtpx:cad>84</gpxtpx:cad>
                  </gpxtpx:TrackPointExtension>
                </extensions>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>

        """

        #expect(GPXWriter.gpx(for: activity, name: "Lunch & <Run>") == expected)
    }
}
