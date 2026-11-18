import Foundation
import GarminExport
import GarminModels

/// The files an activity is shared as: its raw FIT file from the session store, and a GPX track.
enum ActivityExport {
    /// Where SessionStore keeps the raw FIT files: Application Support/OpenGarmin/FIT.
    private static var fitDirectory: URL {
        // Application Support is always available on iOS, as in AppEnvironment.live().
        let support = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        return support.appendingPathComponent("OpenGarmin/FIT", isDirectory: true)
    }

    static func gpxFile(for activity: Activity) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Activity-\(activity.id).gpx")
        try GPXWriter.gpx(for: activity, name: activity.name ?? activity.sport.title)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// nil when the activity's FIT file is not in the store.
    static func fitFile(for activity: Activity, unitNumber: UInt32?) -> URL? {
        FitArchive.fitFile(for: activity, unitNumber: unitNumber, in: fitDirectory)
    }
}
