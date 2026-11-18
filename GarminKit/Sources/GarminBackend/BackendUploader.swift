import Foundation
import GarminModels

/// What one upload run sent. `failure` is set when the run stopped early; the files it did not reach stay pending.
public struct UploadReport: Sendable, Equatable {
    /// Files and batches the server took in this run.
    public var uploaded = 0
    /// Files and batches the server still lacks that were not sent, neither uploaded nor refused.
    public var pending = 0
    /// Files the server refused with a 4xx answer other than 401 and 403, by key, with the server's reason. A run skips
    /// them until it is given an empty map of refusals.
    public var rejected: [String: String] = [:]
    public var failure: BackendError?
}

/// Uploads what the server lacks: the FIT files in `FIT/`, the batches in `Batches/` and the raw Garmin Connect
/// responses in `ConnectRaw/`, under `directory` (the app's Application Support folder). The keys come from `sync/state`,
/// so a run is idempotent and a stopped run resumes on the next one.
public enum BackendUploader {
    /// The folders of the import stage: FIT files in `FIT/`, batches as JSON in `Batches/`, and Garmin Connect responses
    /// as `ConnectRaw/<endpoint>/<day>.json` (`GarminConnect.ConnectRawStore` writes them).
    private static let fitFolder = "FIT"
    private static let batchFolder = "Batches"
    private static let rawFolder = "ConnectRaw"

    /// - Parameter rejected: refusals from earlier runs, by key. Those files are skipped, not tried again. Pass an empty
    ///   map to try every file.
    public static func run(directory: URL, client: BackendClient, rejected: [String: String] = [:]) async -> UploadReport {
        var report = UploadReport()
        let keys: Set<String>
        do {
            keys = try await client.syncState()
        } catch {
            report.failure = failure(error)
            return report
        }
        let missing = localItems(in: directory).filter { !keys.contains($0.key) }
        let missingKeys = Set(missing.map(\.key))
        report.rejected = rejected.filter { missingKeys.contains($0.key) }
        for item in missing where report.rejected[item.key] == nil {
            do {
                try await item.upload(client)
                report.uploaded += 1
            } catch BackendError.rejected(_, let message) {
                report.rejected[item.key] = message
            } catch {
                report.failure = failure(error)
                break
            }
        }
        report.pending = missing.count - report.uploaded - report.rejected.count
        return report
    }

    private static func failure(_ error: Error) -> BackendError {
        error as? BackendError ?? .transport(error.localizedDescription)
    }

    /// Every FIT file and batch on disk, by key, in name order.
    private static func localItems(in directory: URL) -> [Item] {
        let fits = files(in: directory.appending(path: fitFolder, directoryHint: .isDirectory), extension: "fit")
            .map { Item.fit(key: $0.key, url: $0.url) }
        let batches = files(in: directory.appending(path: batchFolder, directoryHint: .isDirectory), extension: "json")
            .map { Item.batch(key: $0.key, url: $0.url) }
        return fits + batches + rawItems(in: directory)
    }

    /// Each raw Garmin Connect response, under `connect-raw-<endpoint>-<day>`. Its fetch time is the file's write time.
    private static func rawItems(in directory: URL) -> [Item] {
        let root = directory.appending(path: rawFolder, directoryHint: .isDirectory)
        let endpoints = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return endpoints.flatMap { folder -> [Item] in
            let endpoint = folder.lastPathComponent
            return files(in: folder, extension: "json").map { file in
                let modified = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return Item.raw(key: "connect-raw-\(endpoint)-\(file.key)", endpoint: endpoint, day: file.key,
                                url: file.url, fetchedAt: modified ?? .now)
            }
        }
    }

    private static func files(in folder: URL, extension ext: String) -> [(key: String, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == ext }
            .map { (key: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.key < $1.key }
    }

    private enum Item {
        case fit(key: String, url: URL)
        case batch(key: String, url: URL)
        case raw(key: String, endpoint: String, day: String, url: URL, fetchedAt: Date)

        var key: String {
            switch self {
            case let .fit(key, _), let .batch(key, _), let .raw(key, _, _, _, _): key
            }
        }

        func upload(_ client: BackendClient) async throws {
            let source = BackendSource(key: key)
            switch self {
            case let .fit(key, url):
                try await client.uploadFIT(try Data(contentsOf: url), key: key, source: source,
                                           deviceUnit: UInt32(key.prefix { $0 != "-" }))
            case let .batch(key, url):
                let batch = try JSONDecoder().decode(HealthBatch.self, from: Data(contentsOf: url))
                try await client.uploadBatch(batch, key: key, source: source)
            case let .raw(key, endpoint, day, url, fetchedAt):
                // A response that is not JSON cannot be sent as one. It is refused, so the run does not stop on it.
                let data = try Data(contentsOf: url)
                guard let body = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
                    throw BackendError.rejected(status: 400, message: "The response is not JSON.")
                }
                try await client.uploadConnectRaw(body, key: key, endpoint: endpoint, day: day, fetchedAt: fetchedAt)
            }
        }
    }
}
