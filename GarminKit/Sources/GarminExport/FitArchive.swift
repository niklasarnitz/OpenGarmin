import Foundation
import GarminFIT
import GarminModels

/// Finds the raw FIT file an activity was imported from. The store names each file with a key that is not kept on
/// the activity, so the files under `directory` are decoded until one holds an activity with the same id.
public enum FitArchive {
    public static func fitFile(for activity: Activity, unitNumber: UInt32?, in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "fit", let data = try? Data(contentsOf: url),
                  let file = try? FitDecoder.decode(data) else { continue }
            let activities = FitExtractor.extract(file, unitNumber: unitNumber).activities
            if activities.contains(where: { $0.id == activity.id }) {
                return url
            }
        }
        return nil
    }
}
