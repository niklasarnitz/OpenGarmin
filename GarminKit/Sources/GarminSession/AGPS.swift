import Foundation
import Observation

/// The AGPS files a watch asks for. Each one is cached on the phone and answered from there, as Gadgetbridge's
/// AgpsInterceptor does, so the watch's AGPS requests never reach Garmin.
public enum AGPSDataType: String, CaseIterable, Identifiable, Sendable, Codable {
    /// A tar with one CPE_*.BIN file per constellation, for requests with a `constellations` query.
    case constellations
    /// A gzip with a timestamp, for `/rxnetworks/` requests. Not sent once it is older than seven days.
    case rxNetworks
    /// Sony CPE data, for `/ephemeris/cpe/sony` requests.
    case sonyCPE

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .constellations: "Satellite orbits"
        case .rxNetworks: "Network hints"
        case .sonyCPE: "Sony CPE"
        }
    }
}

public enum AGPSStatus: Sendable, Equatable {
    case missing
    case current
    /// An rxnetworks file older than seven days, which the watch no longer accepts.
    case expired
    /// The last download or validation failed; the message says why.
    case failed(String)
}

public struct AGPSEntry: Identifiable, Sendable, Equatable {
    public var id: AGPSDataType { type }
    public let type: AGPSDataType
    /// Where the file is downloaded from. Unset until the user sets it or the watch asks for the file.
    public let url: URL?
    public let status: AGPSStatus
    /// When the cached file was last downloaded.
    public let updatedAt: Date?
}

/// The constellations an AGPS tar carries, named as the watch names them in the `constellations` query.
enum AGPSConstellation: String, CaseIterable {
    case gps = "GPS"
    case glonass = "GLONASS"
    case qzss = "QZSS"
    case galileo = "GALILEO"

    /// The file for this constellation inside the tar.
    var fileName: String {
        switch self {
        case .gps: "CPE_GPS.BIN"
        case .glonass: "CPE_GLO.BIN"
        case .qzss: "CPE_QZSS.BIN"
        case .galileo: "CPE_GAL.BIN"
        }
    }
}

/// A file the cache answers a watch request with.
struct AGPSServedFile {
    let type: AGPSDataType
    let data: Data
}

enum AGPSError: LocalizedError {
    case httpStatus(Int)
    case invalidFile(AGPSDataType)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code): "The server answered with HTTP \(code)"
        case let .invalidFile(type): "The download is not a valid \(type.title) file"
        }
    }
}

/// An AGPS file checked the way Gadgetbridge's GarminAgpsFile checks it.
struct AGPSFile {
    private let bytes: [UInt8]

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// Whether the file is complete enough to store: a tar with at least one constellation, a fresh rxnetworks file, or Sony CPE data.
    func isValid(for type: AGPSDataType, now: Date) -> Bool {
        switch type {
        // Garmin's URL carries the watch's own `constellations` subset, so a tar only needs one known constellation
        // here; serving checks the constellations each request asks for.
        case .constellations: isTar && AGPSConstellation.allCases.contains { tarEntryNames.contains($0.fileName) }
        case .rxNetworks: isValidRxNetworks(now: now)
        case .sonyCPE: isValidSonyCPE
        }
    }

    /// Whether the file is a tar that holds the file of every requested constellation.
    func isValidTar(constellations: [String]) -> Bool {
        guard !constellations.isEmpty, isTar else { return false }
        let names = Set(tarEntryNames)
        return constellations.allSatisfy { name in
            guard let constellation = AGPSConstellation(rawValue: name) else { return false }
            return names.contains(constellation.fileName)
        }
    }

    /// Whether the file is a gzip whose payload starts with the rxnetworks header and a timestamp of at most seven days.
    func isValidRxNetworks(now: Date) -> Bool {
        guard let payload = gunzipped, payload.count >= 6, payload[0] == 0x01, payload[1] == 0x00 else { return false }
        let timestamp = payload[2..<6].reduce(0) { $0 << 8 | Int($1) }
        let age = Int(now.timeIntervalSince1970) - timestamp
        return age >= 0 && age <= 7 * 24 * 3600
    }

    var isValidSonyCPE: Bool {
        bytes.starts(with: [0x2a, 0x12, 0xa0, 0x02])
    }

    private var isTar: Bool {
        bytes.count >= 263 && bytes[257..<263].elementsEqual(Self.tarMagic)
    }

    private static let tarMagic: [UInt8] = Array("ustar\0".utf8)

    /// The names of the entries in a USTAR archive, read from the 512-byte headers.
    private var tarEntryNames: [String] {
        var names: [String] = []
        var offset = 0
        while offset + 512 <= bytes.count, bytes[(offset + 257)..<(offset + 263)].elementsEqual(Self.tarMagic) {
            names.append(text(at: offset, length: 100))
            let size = max(0, Int(text(at: offset + 124, length: 12), radix: 8) ?? 0)
            offset += ((size + 511) / 512 + 1) * 512
        }
        return names
    }

    /// The text of a NUL-terminated header field, without its surrounding spaces.
    private func text(at offset: Int, length: Int) -> String {
        let field = bytes[offset..<min(offset + length, bytes.count)].prefix { $0 != 0 }
        return String(decoding: field, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// The payload of the gzip file, decompressed. Foundation's zlib decoder takes raw deflate data, so the gzip
    /// header is skipped first.
    private var gunzipped: [UInt8]? {
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard let end = bytes[min(index, bytes.count)...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }
        if flags & 0x02 != 0 {
            index += 2
        }
        guard index < bytes.count else { return nil }
        guard let data = try? (Data(bytes[index...]) as NSData).decompressed(using: .zlib) as Data else { return nil }
        return [UInt8](data)
    }
}

/// The AGPS files on the phone: one URL and one downloaded file per data type. The app refreshes them in the
/// background, and the watch's AGPS requests are answered from them.
@MainActor
@Observable
public final class AGPSCache {
    /// Gadgetbridge serves its files with max-age=14400, so a file is downloaded at most this often unless forced.
    static let refreshInterval: TimeInterval = 4 * 3600
    /// The hosts Garmin serves AGPS from, as Gadgetbridge's AgpsInterceptor matches them.
    static let hosts: Set<String> = ["api.gcs.garmin.com", "api.gcs.garmin.cn"]

    public private(set) var entries: [AGPSEntry] = []
    public private(set) var isRefreshing = false

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var records: [String: Record] = [:]

    private struct Record: Codable {
        var url: URL?
        var updatedAt: Date?
        var lastError: String?
    }

    public init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
        }
        rebuildEntries()
    }

    /// Sets where the data type is downloaded from. Nothing is downloaded until `refresh`.
    public func setURL(_ url: URL?, for type: AGPSDataType) {
        records[type.rawValue, default: Record()].url = url
        save()
        rebuildEntries()
    }

    /// Downloads every data type that has a URL, and whose file is older than the refresh interval unless `force` is set.
    /// A download that fails or is not valid keeps the file that is cached and shows the error.
    public func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for type in AGPSDataType.allCases {
            guard let url = records[type.rawValue]?.url else { continue }
            if !force, isFresh(type) { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw AGPSError.httpStatus(http.statusCode)
                }
                try install(data, for: type)
            } catch {
                records[type.rawValue]?.lastError = error.localizedDescription
                save()
                rebuildEntries()
            }
        }
    }

    /// Caches a downloaded file if it is valid now. An invalid file is refused and the cached file stays.
    func install(_ data: Data, for type: AGPSDataType) throws {
        guard AGPSFile(data).isValid(for: type, now: .now) else { throw AGPSError.invalidFile(type) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(type), options: .atomic)
        var record = records[type.rawValue] ?? Record()
        record.updatedAt = .now
        record.lastError = nil
        records[type.rawValue] = record
        save()
        rebuildEntries()
    }

    /// The cached file that answers a watch request for `urlString`, or nil when the request is not for AGPS or no
    /// valid file is cached. The first request for a data type also sets its URL, if none is set, so the user can
    /// refresh from the URL the watch asked for.
    func servedFile(for urlString: String) -> AGPSServedFile? {
        guard let components = URLComponents(string: urlString), let host = components.host,
              Self.hosts.contains(host) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        let path = components.path
        guard path.hasPrefix("/ephemeris/") else { return nil }
        let type: AGPSDataType
        if query["constellations"] != nil {
            type = .constellations
        } else if path.contains("/rxnetworks/") {
            type = .rxNetworks
        } else if path.hasPrefix("/ephemeris/cpe/sony") {
            type = .sonyCPE
        } else {
            return nil
        }

        if records[type.rawValue]?.url == nil {
            records[type.rawValue, default: Record()].url = URL(string: urlString)
            save()
            rebuildEntries()
        }
        guard let data = try? Data(contentsOf: fileURL(type)) else { return nil }
        let file = AGPSFile(data)
        let valid = switch type {
        case .constellations:
            file.isValidTar(constellations: (query["constellations"] ?? "").split(separator: ",").map(String.init))
        default:
            file.isValid(for: type, now: .now)
        }
        return valid ? AGPSServedFile(type: type, data: data) : nil
    }

    private func isFresh(_ type: AGPSDataType) -> Bool {
        guard let updated = records[type.rawValue]?.updatedAt else { return false }
        return Date.now.timeIntervalSince(updated) < Self.refreshInterval
            && FileManager.default.fileExists(atPath: fileURL(type).path)
    }

    private func fileURL(_ type: AGPSDataType) -> URL {
        directory.appendingPathComponent("\(type.rawValue).bin")
    }

    private func rebuildEntries() {
        entries = AGPSDataType.allCases.map { type in
            let record = records[type.rawValue]
            return AGPSEntry(type: type, url: record?.url, status: status(of: type), updatedAt: record?.updatedAt)
        }
    }

    private func status(of type: AGPSDataType) -> AGPSStatus {
        if let error = records[type.rawValue]?.lastError { return .failed(error) }
        guard let data = try? Data(contentsOf: fileURL(type)) else { return .missing }
        if AGPSFile(data).isValid(for: type, now: .now) { return .current }
        return type == .rxNetworks ? .expired : .failed("The cached file is no longer valid")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}
