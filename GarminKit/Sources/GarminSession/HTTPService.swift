import CryptoKit
import Foundation
import GarminProtobuf

/// Answers the watch's HTTP and data transfer requests, as Gadgetbridge's HttpHandler does for the ones that matter
/// here. AGPS requests are answered from the AGPS cache. Every other HTTP request is blocked: the watch gets a
/// network timeout and nothing is sent to Garmin. A payload too large for the protobuf reply is kept for the watch
/// to pull over the data transfer service.
@MainActor
final class WatchHTTPService {
    /// Payloads the watch can still pull. The oldest is dropped beyond this.
    private static let maxPayloads = 8

    private struct Answer {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private let agps: AGPSCache?
    private var payloads: [(id: UInt32, data: Data)] = []
    private var lastPayloadID = UInt32.random(in: 0..<(UInt32.max / 2))

    /// - Parameter agps: the AGPS cache. nil answers no AGPS request.
    init(agps: AGPSCache?) {
        self.agps = agps
    }

    /// The reply to an HTTP or data transfer request from the watch, or nil when the request gets no reply.
    func reply(to smart: GarminVivomovehr_Smart) -> GarminVivomovehr_Smart? {
        var reply = GarminVivomovehr_Smart()
        if smart.hasConnectIqHTTPService {
            guard let service = handle(smart.connectIqHTTPService) else { return nil }
            reply.connectIqHTTPService = service
        } else if smart.hasDataTransferService, smart.dataTransferService.hasDataDownloadRequest {
            reply.dataTransferService = dataDownload(smart.dataTransferService.dataDownloadRequest)
        } else {
            return nil
        }
        return reply
    }

    private func handle(_ service: GDI_Proto_ConnectIQHTTP_ConnectIQHTTPService) -> GDI_Proto_ConnectIQHTTP_ConnectIQHTTPService? {
        var reply = GDI_Proto_ConnectIQHTTP_ConnectIQHTTPService()
        if service.hasRawResourceRequest {
            guard let response = rawResponse(service.rawResourceRequest) else { return nil }
            reply.rawResourceResponse = response
        } else if service.hasConnectIqHTTPRequest {
            // Web requests are not answered from the cache, so they are blocked.
            var response = GDI_Proto_ConnectIQHTTP_ConnectIQHTTPResponse()
            response.status = .networkRequestTimedOut
            response.httpStatusCode = 0
            reply.connectIqHTTPResponse = response
        } else {
            return nil
        }
        return reply
    }

    /// Gadgetbridge's HttpHandler.handleRawRequest. A multipart form is not supported, so it gets no reply.
    private func rawResponse(_ request: GDI_Proto_ConnectIQHTTP_RawResourceRequest) -> GDI_Proto_ConnectIQHTTP_RawResourceResponse? {
        guard request.forms.isEmpty else { return nil }
        var headers: [String: String] = [:]
        for header in request.headers {
            headers[header.key.lowercased()] = header.value
        }
        var response = GDI_Proto_ConnectIQHTTP_RawResourceResponse()
        guard let answer = answer(url: request.url, headers: headers) else {
            response.status = .networkRequestTimedOut
            return response
        }
        response.status = .ok
        response.httpStatusCode = Int32(answer.status)
        response.headers = answer.headers.map { key, value in
            var header = GDI_Proto_ConnectIQHTTP_RawResourceResponse.HTTPHeader()
            header.key = key
            header.value = value
            return header
        }
        if request.useDataXfer {
            var item = GDI_Proto_DataTypes_DataTransferItem()
            item.id = register(answer.body)
            item.size = UInt32(answer.body.count)
            response.xferData = item
        } else {
            response.resourceData = answer.body
        }
        return response
    }

    /// Gadgetbridge's AgpsInterceptor: the cached file, with an ETag, and a 304 when the watch already has that file.
    /// Any other URL gets no answer.
    private func answer(url: String, headers: [String: String]) -> Answer? {
        guard let served = agps?.servedFile(for: url) else { return nil }
        let etag = "\"" + Insecure.MD5.hash(data: served.data).map { String(format: "%02x", $0) }.joined() + "\""
        var answer = Answer(status: 200, headers: [
            "etag": etag,
            "cache-control": "max-age=14400",
            "Content-Type": headers["accept"] ?? "application/octet-stream",
        ], body: served.data)
        if headers["if-none-match"] == etag {
            answer.status = 304
            answer.body = Data()
        }
        return answer
    }

    /// Gadgetbridge's DataTransferHandler.handleDataDownloadRequest: one chunk of a registered payload, from the offset
    /// the watch asked for.
    private func dataDownload(_ request: GDI_Proto_DataTransfer_DataDownloadRequest) -> GDI_Proto_DataTransfer_DataTransferService {
        var download = GDI_Proto_DataTransfer_DataDownloadResponse()
        download.id = request.id
        download.offset = request.offset
        guard let data = payloads.first(where: { $0.id == request.id })?.data else {
            download.status = .invalidID
            return dataTransfer(download)
        }
        let offset = Int(request.offset)
        guard offset < data.count else {
            download.status = .invalidOffset
            return dataTransfer(download)
        }
        let end = request.hasMaxChunkSize && request.maxChunkSize > 0
            ? min(data.count, offset + Int(request.maxChunkSize))
            : data.count
        download.status = .success
        download.payload = Data(data[offset..<end])
        return dataTransfer(download)
    }

    private func dataTransfer(_ download: GDI_Proto_DataTransfer_DataDownloadResponse) -> GDI_Proto_DataTransfer_DataTransferService {
        var service = GDI_Proto_DataTransfer_DataTransferService()
        service.dataDownloadResponse = download
        return service
    }

    /// Keeps a payload for the watch to pull, and returns the id it pulls it by.
    private func register(_ data: Data) -> UInt32 {
        lastPayloadID &+= 1
        payloads.append((lastPayloadID, data))
        if payloads.count > Self.maxPayloads { payloads.removeFirst() }
        return lastPayloadID
    }
}
