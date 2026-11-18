import CryptoKit
import Foundation
import Testing
import GarminCore
import GarminProtobuf
import GarminProtocol
import GarminTransport
@testable import GarminSession

/// A protobuf request the watch sends, as one PROTOBUF_REQUEST frame.
private func watchRequest(_ smart: GarminVivomovehr_Smart, requestID: UInt16) -> GFDIFrame {
    let bytes = try! smart.serializedData()
    let chunk = GFDIProtobufChunk(requestID: requestID, dataOffset: 0, totalLength: UInt32(bytes.count), data: bytes)
    return GFDIProtobufRequest(chunk: chunk).frame()
}

/// A raw resource request for `url`, as the watch's HTTP service sends it.
private func rawRequest(_ url: String, headers: [(String, String)] = [], useDataXfer: Bool = false) -> GarminVivomovehr_Smart {
    var raw = GDI_Proto_ConnectIQHTTP_RawResourceRequest()
    raw.url = url
    raw.method = .get
    raw.useDataXfer = useDataXfer
    raw.headers = headers.map { key, value in
        var header = GDI_Proto_ConnectIQHTTP_RawResourceRequest.HTTPHeader()
        header.key = key
        header.value = value
        return header
    }
    var service = GDI_Proto_ConnectIQHTTP_ConnectIQHTTPService()
    service.rawResourceRequest = raw
    var smart = GarminVivomovehr_Smart()
    smart.connectIqHTTPService = service
    return smart
}

private func dataDownload(id: UInt32, offset: UInt32, maxChunkSize: UInt32) -> GarminVivomovehr_Smart {
    var request = GDI_Proto_DataTransfer_DataDownloadRequest()
    request.id = id
    request.offset = offset
    request.maxChunkSize = maxChunkSize
    var service = GDI_Proto_DataTransfer_DataTransferService()
    service.dataDownloadRequest = request
    var smart = GarminVivomovehr_Smart()
    smart.dataTransferService = service
    return smart
}

/// The payload of the phone's reply to the request with `requestID`, once every chunk of it has arrived.
@MainActor
private func reply(_ link: FakeLink, requestID: UInt16) -> Data? {
    var reassembler = GFDIProtobufReassembler()
    var complete: Data?
    for frame in link.framesSent(of: .protobufResponse) {
        guard let response = GFDIMessageParser.parse(frame) as? GFDIProtobufResponse,
              response.chunk.requestID == requestID else { continue }
        if let bytes = try? reassembler.accept(response.chunk) { complete = bytes }
    }
    return complete
}

@MainActor
private func replySmart(_ link: FakeLink, requestID: UInt16) throws -> GarminVivomovehr_Smart? {
    guard let bytes = reply(link, requestID: requestID) else { return nil }
    return try GarminVivomovehr_Smart(serializedBytes: bytes)
}

@MainActor
private func waitForReply(_ link: FakeLink, requestID: UInt16) async throws {
    for _ in 0..<500 {
        if reply(link, requestID: requestID) != nil { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("no reply to request \(requestID) within 5 seconds")
}

@MainActor
private func makeSession(link: FakeLink, agps: AGPSCache) throws -> GFDISession {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = try SessionStore(directory: directory, defaults: defaults)
    return GFDISession(link: link, importer: makeImporter(store), capabilities: [], phoneName: "iPhone",
                       weatherProvider: nil, agps: agps) { _ in }
}

@MainActor
private func makeAGPSCache() -> AGPSCache {
    AGPSCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}

private func md5Etag(_ data: Data) -> String {
    "\"" + Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\""
}

private let agpsURL = "https://api.gcs.garmin.com/ephemeris/v2/tar?constellations=GPS,GLONASS"

@MainActor
@Test func agpsRequestIsAnsweredFromTheCachedFile() async throws {
    let cache = makeAGPSCache()
    let tar = completeAGPSTar(gps: Data(repeating: 1, count: 700))
    try cache.install(tar, for: .constellations)
    let link = FakeLink()
    let session = try makeSession(link: link, agps: cache)
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    link.watchSends(watchRequest(rawRequest(agpsURL, headers: [("accept", "application/x-garmin-tar")]), requestID: 7))
    try await waitForReply(link, requestID: 7)

    let raw = try #require(try replySmart(link, requestID: 7)).connectIqHTTPService.rawResourceResponse
    #expect(raw.status == .ok)
    #expect(raw.httpStatusCode == 200)
    #expect(raw.resourceData == tar)
    let headers = Dictionary(uniqueKeysWithValues: raw.headers.map { ($0.key, $0.value) })
    #expect(headers["etag"] == md5Etag(tar))
    #expect(headers["cache-control"] == "max-age=14400")
    #expect(headers["Content-Type"] == "application/x-garmin-tar")

    // The watch already has this file: a 304 with no body.
    link.watchSends(watchRequest(rawRequest(agpsURL, headers: [("if-none-match", md5Etag(tar))]), requestID: 8))
    try await waitForReply(link, requestID: 8)
    let notModified = try #require(try replySmart(link, requestID: 8)).connectIqHTTPService.rawResourceResponse
    #expect(notModified.httpStatusCode == 304)
    #expect(notModified.resourceData.isEmpty)
}

@MainActor
@Test func agpsFileIsPulledOverTheDataTransferService() async throws {
    let cache = makeAGPSCache()
    let tar = completeAGPSTar(gps: Data(repeating: 1, count: 1500))
    try cache.install(tar, for: .constellations)
    let link = FakeLink()
    let session = try makeSession(link: link, agps: cache)
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    link.watchSends(watchRequest(rawRequest(agpsURL, useDataXfer: true), requestID: 7))
    try await waitForReply(link, requestID: 7)
    let item = try #require(try replySmart(link, requestID: 7)).connectIqHTTPService.rawResourceResponse.xferData
    #expect(item.size == UInt32(tar.count))

    // The watch pulls the file in chunks of at most 1000 bytes, and the chunks join back into the tar.
    var pulled = Data()
    var offset: UInt32 = 0
    var requestID: UInt16 = 10
    while pulled.count < tar.count {
        link.watchSends(watchRequest(dataDownload(id: item.id, offset: offset, maxChunkSize: 1000), requestID: requestID))
        try await waitForReply(link, requestID: requestID)
        let download = try #require(try replySmart(link, requestID: requestID)).dataTransferService.dataDownloadResponse
        #expect(download.status == .success)
        guard download.status == .success else { break }
        pulled += download.payload
        offset += UInt32(download.payload.count)
        requestID += 1
    }
    #expect(pulled == tar)
}

@MainActor
@Test func requestsWithoutACachedAGPSFileAndOtherURLsAreBlocked() async throws {
    let cache = makeAGPSCache()
    let link = FakeLink()
    let session = try makeSession(link: link, agps: cache)
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    // Nothing is cached yet, so the AGPS request times out instead of reaching Garmin.
    link.watchSends(watchRequest(rawRequest(agpsURL), requestID: 7))
    // Other Garmin endpoints and other hosts are blocked the same way.
    link.watchSends(watchRequest(rawRequest("https://api.garmin.com/weather/v1/current?lat=1&lon=2"), requestID: 8))
    link.watchSends(watchRequest(rawRequest("https://example.com/data.json"), requestID: 9))
    for id: UInt16 in [7, 8, 9] {
        try await waitForReply(link, requestID: id)
        let raw = try #require(try replySmart(link, requestID: id)).connectIqHTTPService.rawResourceResponse
        #expect(raw.status == .networkRequestTimedOut)
        #expect(raw.resourceData.isEmpty)
    }
    #expect(cache.entries.allSatisfy { $0.status == .missing })
}
