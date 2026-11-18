import Foundation

/// Garmin's responses as they arrived, one file each: `<directory>/<endpoint>/<name>.json`. A daily response is named by
/// its day, an activity list page by its range and start. The backend upload sends each file once, and a later parser
/// reads the file again instead of asking Garmin.
public struct ConnectRawStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes the body unchanged, atomically, so a crash leaves either the whole response or none.
    func save(_ body: Data, endpoint: String, name: String) throws {
        let folder = directory.appending(path: endpoint, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try body.write(to: folder.appending(path: name + ".json"), options: .atomic)
    }

    func load(endpoint: String, name: String) -> Data? {
        try? Data(contentsOf: directory.appending(path: endpoint, directoryHint: .isDirectory)
            .appending(path: name + ".json"))
    }
}
