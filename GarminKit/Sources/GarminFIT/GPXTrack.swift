import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A point of a GPX track: latitude and longitude in degrees, and the altitude in metres when the file has one.
public struct GPXTrackPoint: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public enum GPXError: Error, Equatable, Sendable {
    case notGPX
    case noTrackPoints
}

extension GPXError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notGPX: "This is not a GPX file."
        case .noTrackPoints: "The GPX file has no track points."
        }
    }
}

/// Reads a GPX file the way Gadgetbridge does: the points of the first track, all of its segments in order.
public enum GPXTrack {
    public static func points(in data: Data) throws -> [GPXTrackPoint] {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.isGPX else { throw GPXError.notGPX }
        guard !reader.points.isEmpty else { throw GPXError.noTrackPoints }
        return reader.points
    }
}

private final class GPXReader: NSObject, XMLParserDelegate {
    private(set) var points: [GPXTrackPoint] = []
    private(set) var isGPX = false
    private var tracks = 0
    private var current: GPXTrackPoint?
    private var readingElevation = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "gpx":
            isGPX = true
        case "trk":
            tracks += 1
        case "trkpt" where tracks == 1:
            if let lat = Double(attributeDict["lat"] ?? ""), let lon = Double(attributeDict["lon"] ?? "") {
                current = GPXTrackPoint(latitude: lat, longitude: lon)
            }
        case "ele" where current != nil:
            readingElevation = true
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingElevation { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "ele" where readingElevation:
            current?.altitude = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            readingElevation = false
        case "trkpt":
            if let point = current { points.append(point) }
            current = nil
        default:
            break
        }
    }
}
