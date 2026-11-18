import Foundation
import Testing
@testable import GarminSession

/// A USTAR archive of the given files, laid out like the watch's AGPS tars: a 512-byte header per file, the data
/// padded to whole blocks, and two zero blocks at the end.
func agpsTar(_ files: [(name: String, data: Data)]) -> Data {
    var archive = Data()
    for file in files {
        var header = Data(repeating: 0, count: 512)
        header.replaceSubrange(0..<file.name.utf8.count, with: Array(file.name.utf8))
        let size = Array(String(format: "%011o", file.data.count).utf8) + [0]
        header.replaceSubrange(100..<108, with: Array("0000644\0".utf8))
        header.replaceSubrange(124..<136, with: size)
        header[156] = UInt8(ascii: "0")
        header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
        archive += header
        archive += file.data
        archive += Data(repeating: 0, count: (512 - file.data.count % 512) % 512)
    }
    return archive + Data(repeating: 0, count: 1024)
}

/// The rxnetworks payload: version 1 0, then the timestamp big endian. Gzipped with the gzip tool, so the headers are real.
private let rxNetworksTimestamp: TimeInterval = 1_800_000_000
/// gzip -n of the payload: no file name in the header.
private let rxNetworksPlain = "H4sIAAAAAAAAA2NkyPa8xFCcn5uqUFKUmJmTmZeukJheUKyQkliSqJBUWZJarFCSkViikJyfW1CUWlysABTNLNFRwKsFAFwBBApWAAAA"
/// gzip of a file named rxnetworks.bin: the header carries the name, which the reader has to skip.
private let rxNetworksNamed = "H4sICDKl/WoAA3J4bmV0d29ya3MuYmluAGNkyPa8xFCcn5uqUFKUmJmTmZeukJheUKyQkliSqJBUWZJarFCSkViikJyfW1CUWlysABTNLNFRwKsFAFwBBApWAAAA"

private func decoded(_ base64: String) -> Data {
    Data(base64Encoded: base64)!
}

private let sonyCPE = Data([0x2a, 0x12, 0xa0, 0x02, 0x01, 0x02, 0x03])

@Test func rxNetworksIsValidOnlyWithinSevenDaysOfItsTimestamp() {
    let file = AGPSFile(decoded(rxNetworksPlain))
    let day: TimeInterval = 24 * 3600
    // Exactly seven days old is still fresh; a second more is not.
    #expect(file.isValidRxNetworks(now: Date(timeIntervalSince1970: rxNetworksTimestamp + 7 * day)))
    #expect(!file.isValidRxNetworks(now: Date(timeIntervalSince1970: rxNetworksTimestamp + 7 * day + 1)))
    // A file dated in the future is refused; one dated right now is fine.
    #expect(!file.isValidRxNetworks(now: Date(timeIntervalSince1970: rxNetworksTimestamp - 1)))
    #expect(file.isValidRxNetworks(now: Date(timeIntervalSince1970: rxNetworksTimestamp)))
}

@Test func rxNetworksReadsGzipHeadersWithAFileName() {
    let now = Date(timeIntervalSince1970: rxNetworksTimestamp + 3600)
    #expect(AGPSFile(decoded(rxNetworksPlain)).isValidRxNetworks(now: now))
    #expect(AGPSFile(decoded(rxNetworksNamed)).isValidRxNetworks(now: now))
    // Not gzip, and a gzip with a corrupt body, are refused.
    #expect(!AGPSFile(sonyCPE).isValidRxNetworks(now: now))
    #expect(!AGPSFile(Data([0x1f, 0x8b, 0x08, 0x00] + [UInt8](repeating: 0xff, count: 24))).isValidRxNetworks(now: now))
}

@Test func sonyCPEIsRecognisedByItsHeader() {
    #expect(AGPSFile(sonyCPE).isValid(for: .sonyCPE, now: .now))
    #expect(!AGPSFile(Data([0x2a, 0x12, 0xa0, 0x03])).isValid(for: .sonyCPE, now: .now))
    #expect(!AGPSFile(Data([0x2a, 0x12])).isValid(for: .sonyCPE, now: .now))
}

@Test func tarNeedsTheFileOfEveryRequestedConstellation() {
    // The GLONASS file comes after a 700-byte file, so the walk over the headers has to skip whole blocks.
    let tar = AGPSFile(agpsTar([
        ("CPE_GPS.BIN", Data(repeating: 1, count: 700)),
        ("CPE_GLO.BIN", Data(repeating: 2, count: 10)),
    ]))
    #expect(tar.isValidTar(constellations: ["GPS"]))
    #expect(tar.isValidTar(constellations: ["GLONASS", "GPS"]))
    #expect(!tar.isValidTar(constellations: ["GPS", "GALILEO"]))
    #expect(!tar.isValidTar(constellations: ["NAVIC"]))
    #expect(!tar.isValidTar(constellations: []))
    #expect(!tar.isValid(for: .constellations, now: .now), "a tar without QZSS and GALILEO is not stored")
    #expect(!AGPSFile(Data(repeating: 0, count: 2048)).isValidTar(constellations: ["GPS"]))
}

/// A tar with the file of every constellation, as a complete AGPS download has. The GPS file's content is `gps`.
func completeAGPSTar(gps: Data = Data([1, 2])) -> Data {
    agpsTar(AGPSConstellation.allCases.map { (name: $0.fileName, data: $0 == .gps ? gps : Data([3])) })
}

@Test func storedTarHasEveryConstellation() {
    let all = AGPSConstellation.allCases.map { (name: $0.fileName, data: Data([1, 2, 3])) }
    #expect(AGPSFile(agpsTar(all)).isValid(for: .constellations, now: .now))
}

@MainActor
private func makeCache() -> AGPSCache {
    AGPSCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}

@MainActor
@Test func cacheStoresOnlyValidFilesAndReportsTheirStatus() throws {
    let cache = makeCache()
    #expect(cache.entries.allSatisfy { $0.status == .missing && $0.url == nil })

    #expect(throws: AGPSError.self) { try cache.install(Data([9, 9, 9]), for: .constellations) }
    #expect(cache.entries.allSatisfy { $0.status == .missing && $0.updatedAt == nil })

    try cache.install(sonyCPE, for: .sonyCPE)
    let sony = try #require(cache.entries.first { $0.type == .sonyCPE })
    #expect(sony.status == .current)
    #expect(sony.updatedAt != nil)
    #expect(cache.entries.first { $0.type == .constellations }?.status == .missing)
}

@MainActor
@Test func cacheAnswersOnlyAGPSRequestsItHasAValidFileFor() throws {
    let cache = makeCache()
    let tar = completeAGPSTar()
    try cache.install(tar, for: .constellations)
    let url = "https://api.gcs.garmin.com/ephemeris/v2/tar?constellations=GPS,GLONASS"

    // A subset of the cached constellations is served, with the tar as stored.
    let served = try #require(cache.servedFile(for: url))
    #expect(served.type == .constellations)
    #expect(served.data == tar)
    // The URL the watch asked for becomes this type's URL, because none was set.
    #expect(cache.entries.first { $0.type == .constellations }?.url == URL(string: url))

    // A constellation the cache does not have, an unknown constellation, another host, another path: not served.
    #expect(cache.servedFile(for: "https://api.gcs.garmin.com/ephemeris/v2/tar?constellations=NAVIC") == nil)
    #expect(cache.servedFile(for: "https://example.com/ephemeris/v2/tar?constellations=GPS") == nil)
    #expect(cache.servedFile(for: "https://api.gcs.garmin.com/weather/v1/current?lat=1&lon=2") == nil)
    #expect(cache.servedFile(for: "https://api.gcs.garmin.com/ephemeris/cpe/sony") == nil, "no Sony file is cached")
}

@MainActor
@Test func cacheDoesNotChangeTheURLOnceOneIsSet() throws {
    let cache = makeCache()
    cache.setURL(URL(string: "https://mirror.example/agps.tar"), for: .constellations)
    try cache.install(completeAGPSTar(), for: .constellations)
    _ = cache.servedFile(for: "https://api.gcs.garmin.com/ephemeris/v2/tar?constellations=GPS")
    #expect(cache.entries.first { $0.type == .constellations }?.url == URL(string: "https://mirror.example/agps.tar"))
}
