import Foundation
import GarminModels

/// Writes an activity's track as GPX 1.1. Only records with a position become track points. Heart rate and cadence
/// go in Garmin's track point extension, where other apps look for them in Garmin's own exports.
public enum GPXWriter {
    public static func gpx(for activity: Activity, name: String) -> String {
        let title = escape(name)
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="OpenGarmin" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">"#,
            "  <metadata>",
            "    <name>\(title)</name>",
            "    <time>\(time(activity.start))</time>",
            "  </metadata>",
            "  <trk>",
            "    <name>\(title)</name>",
            "    <trkseg>",
        ]
        for record in activity.records {
            guard let latitude = record.latitude, let longitude = record.longitude else { continue }
            lines.append("      <trkpt lat=\"\(String(format: "%.7f", latitude))\" lon=\"\(String(format: "%.7f", longitude))\">")
            if let altitude = record.altitude {
                lines.append("        <ele>\(String(format: "%.1f", altitude))</ele>")
            }
            lines.append("        <time>\(time(record.date))</time>")
            if record.heartRate != nil || record.cadence != nil {
                lines.append("        <extensions>")
                lines.append("          <gpxtpx:TrackPointExtension>")
                if let heartRate = record.heartRate {
                    lines.append("            <gpxtpx:hr>\(heartRate)</gpxtpx:hr>")
                }
                if let cadence = record.cadence {
                    lines.append("            <gpxtpx:cad>\(cadence)</gpxtpx:cad>")
                }
                lines.append("          </gpxtpx:TrackPointExtension>")
                lines.append("        </extensions>")
            }
            lines.append("      </trkpt>")
        }
        lines += ["    </trkseg>", "  </trk>", "</gpx>", ""]
        return lines.joined(separator: "\n")
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
            .replacing("'", with: "&apos;")
    }
}
