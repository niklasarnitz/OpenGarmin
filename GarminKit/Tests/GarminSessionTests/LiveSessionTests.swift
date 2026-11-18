import Testing
import Foundation
import GarminModels
import GarminProtobuf
import GarminProtocol
import GarminTransport
@testable import GarminSession

/// A realtime service the test watch opened. The test pushes readings into `sink` and records what the app sends.
@MainActor
final class FakeLiveChannel: GarminServiceChannel {
    nonisolated let incoming: AsyncStream<Data>
    nonisolated let sink: AsyncStream<Data>.Continuation
    private(set) var sent: [Data] = []

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        incoming = stream
        sink = continuation
    }

    func send(_ payload: Data) async throws {
        sent.append(payload)
    }
}

/// A link whose watch opens realtime services on request.
@MainActor
final class FakeRealtimeLink: GarminServiceLink, GarminRealtimeLink {
    nonisolated let states = AsyncStream.makeStream(of: LinkState.self).stream
    nonisolated let incomingFrames = AsyncStream.makeStream(of: Data.self).stream
    private(set) var channels: [UInt16: FakeLiveChannel] = [:]

    func connect() async throws {}
    func disconnect() async {}
    func send(_ gfdiFrame: Data) async throws {}
    func openFileTransfer() async throws -> any GarminServiceChannel { throw GarminLinkError.notReady }

    func openRealtimeService(_ service: UInt16) async throws -> any GarminServiceChannel {
        let channel = FakeLiveChannel()
        channels[service] = channel
        return channel
    }
}

@MainActor
@Test func liveSessionStreamsWantedMetricsAndStopsThemWhenUnwanted() async throws {
    let link = FakeRealtimeLink()
    var outputs: [GFDISessionOutput] = []
    let session = GFDISession(link: link, store: try makeStore(), capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { outputs.append($0) }

    session.setLive([.heartRate])
    try await waitUntil { link.channels[6] != nil }
    let channel = try #require(link.channels[6])
    try await waitUntil { channel.sent.count == 1 }
    #expect(channel.sent == [Data([0x01])])

    // A zero bpm sample is dropped; the next valid one is forwarded with its resting value.
    channel.sink.yield(Data([0x00, 0, 58]))
    channel.sink.yield(Data([0x00, 72, 58]))
    try await waitUntil { outputs.count == 1 }
    #expect(outputs.count == 1)
    if case let .live(reading) = outputs.first {
        #expect(reading == .heartRate(bpm: 72, resting: 58))
    } else {
        Issue.record("expected a live reading")
    }

    // Dropping the metric ends its stream, and the watch is told to stop it.
    session.setLive([])
    try await waitUntil { channel.sent.count == 2 }
    #expect(channel.sent.last == Data([0x00]))
    #expect(link.channels.count == 1)
}

@MainActor
@Test func emergencyContactsAnswerTheWatchContactRequestOnlyForProtobuf() throws {
    let contact = EmergencyContact(name: "Anna Arnitz", phoneNumber: "+49 151 2345678")
    let http = WatchHTTPService(agps: nil, contacts: { [contact] })

    func contactsRequest(accept: String) -> GarminVivomovehr_Smart {
        var raw = GDI_Proto_ConnectIQHTTP_RawResourceRequest()
        raw.url = "https://connectapi.garmin.com/device-gateway/usercontact/contacts"
        raw.method = .get
        var header = GDI_Proto_ConnectIQHTTP_RawResourceRequest.HTTPHeader()
        header.key = "accept"
        header.value = accept
        raw.headers = [header]
        var service = GDI_Proto_ConnectIQHTTP_ConnectIQHTTPService()
        service.rawResourceRequest = raw
        var smart = GarminVivomovehr_Smart()
        smart.connectIqHTTPService = service
        return smart
    }

    let reply = try #require(http.reply(to: contactsRequest(accept: "application/octet-stream")))
    let response = reply.connectIqHTTPService.rawResourceResponse
    #expect(response.httpStatusCode == 200)
    let contacts = try Garmin_Response(serializedBytes: response.resourceData)
    #expect(contacts.contact.count == 1)
    #expect(contacts.contact[0].fullName == "Anna Arnitz")
    #expect(contacts.contact[0].phone[0].number == "+49 151 2345678")
    #expect(contacts.contact[0].phone[0].unk12.map(\.unk1) == [1, 2])

    // A request for another content type is not answered, so the watch times out.
    let timedOut = try #require(http.reply(to: contactsRequest(accept: "application/json")))
    #expect(timedOut.connectIqHTTPService.rawResourceResponse.status == .networkRequestTimedOut)
}
