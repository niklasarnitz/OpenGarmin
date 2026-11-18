import Foundation
import Testing
import GarminModels
import GarminProtobuf
import GarminProtocol
import GarminTransport
@testable import GarminSession

private func at(_ unixSeconds: UInt64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(unixSeconds))
}

/// An expected watch event, with only the fields Gadgetbridge sets for it.
private func watchEvent(_ title: String, start: UInt64, end: UInt64, allDay: Bool = false,
                        location: String? = nil, description: String? = nil) -> GDI_Proto_Calendar_CalendarEvent {
    var item = GDI_Proto_Calendar_CalendarEvent()
    item.title = title
    item.startDate = start
    item.endDate = end
    item.allDay = allDay
    if let location { item.location = location }
    if let description { item.description_p = description }
    return item
}

/// A watch request for 2026-11-18 00:00 to 2026-11-21 00:00 UTC, with the options a Venu sends.
private func calendarRequest() -> GarminVivomovehr_Smart {
    var request = GDI_Proto_Calendar_CalendarEventsRequest()
    request.startDate = 1_794_960_000
    request.endDate = 1_795_219_200
    request.includeAllDay = true
    request.includeLocation = true
    request.includeDescription = true
    request.maxTitleLength = 8
    request.maxLocationLength = 6
    request.maxDescriptionLength = 5
    request.maxEvents = 100
    var service = GDI_Proto_Calendar_CalendarService()
    service.calendarEventsRequest = request
    var smart = GarminVivomovehr_Smart()
    smart.calendarEventsService = service
    return smart
}

@MainActor
@Test func calendarRequestGetsTheEventsInRangeWithRequestedFields() async throws {
    let store = try makeStore()
    store.pairedWatch = PairedWatch(id: UUID(), name: "Venu 4", catalogID: "garmin_venu_4")
    let link = FakeLink()
    link.watchSends(deviceInformationFrame())
    link.watchSends(GFDIConfiguration(capabilities: [.sync, .gncs, .findMyWatch]).frame())
    let events = [
        // Ends exactly when the range starts: included, as Gadgetbridge keeps end >= start.
        CalendarEvent(id: "handover", title: "Handover", start: at(1_794_873_600), end: at(1_794_960_000), isAllDay: false),
        // Starts before the range and ends inside it: a multi-day event, cut to 8 title and 6 location characters.
        CalendarEvent(id: "offsite", title: "Conference offsite", location: "Berlin Hall 3", notes: "Bring badge",
                      start: at(1_794_952_800), end: at(1_795_053_600), isAllDay: false),
        CalendarEvent(id: "standup", title: "Standup", notes: "Daily sync",
                      start: at(1_794_992_400), end: at(1_794_996_000), isAllDay: false),
        CalendarEvent(id: "lunch", title: "Lunch with Ana", location: "Kantine",
                      start: at(1_795_003_200), end: at(1_795_006_800), isAllDay: false),
        // All-day: local midnight to the next midnight.
        CalendarEvent(id: "holiday", title: "Holiday", start: at(1_795_046_400), end: at(1_795_132_800), isAllDay: true),
        // Starts exactly when the range ends: included, as Gadgetbridge only drops begin > end.
        CalendarEvent(id: "edge", title: "Edge", start: at(1_795_219_200), end: at(1_795_222_800), isAllDay: false),
        // Outside the range on both sides: excluded.
        CalendarEvent(id: "december", title: "Far away", start: at(1_796_119_200), end: at(1_796_122_800), isAllDay: false),
        CalendarEvent(id: "november", title: "Last week", start: at(1_794_301_200), end: at(1_794_304_800), isAllDay: false),
    ]
    let service = GarminWatchService(store: store, calendar: { events }, makeLink: { _ in link })
    // The phone pushes the events right after the handshake and then starts a sync, so wait for that sync.
    try await waitUntil { link.sent.count >= 12 }

    let requestID: UInt16 = 7
    let bytes = try calendarRequest().serializedData()
    link.watchSends(GFDIProtobufRequest(chunk: GFDIProtobufChunk(requestID: requestID, dataOffset: 0,
                                                                  totalLength: UInt32(bytes.count), data: bytes)).frame())
    try await waitUntil { link.framesSent(of: .protobufResponse).count == 1 }

    let response = try GFDIProtobufResponse(frame: link.framesSent(of: .protobufResponse)[0])
    #expect(response.chunk.requestID == requestID)

    var expectedResponse = GDI_Proto_Calendar_CalendarEventsResponse()
    expectedResponse.status = .ok
    expectedResponse.events = [
        watchEvent("Handover", start: 1_794_873_600, end: 1_794_960_000),
        watchEvent("Conferen", start: 1_794_952_800, end: 1_795_053_600, location: "Berlin", description: "Bring"),
        watchEvent("Standup", start: 1_794_992_400, end: 1_794_996_000, description: "Daily"),
        watchEvent("Lunch wi", start: 1_795_003_200, end: 1_795_006_800, location: "Kantin"),
        watchEvent("Holiday", start: 1_795_046_400, end: 1_795_132_800, allDay: true),
        watchEvent("Edge", start: 1_795_219_200, end: 1_795_222_800),
    ]
    var expected = GDI_Proto_Calendar_CalendarService()
    expected.calendarEventsResponse = expectedResponse
    var expectedSmart = GarminVivomovehr_Smart()
    expectedSmart.calendarEventsService = expected
    #expect(response.chunk.data == (try expectedSmart.serializedData()))
    withExtendedLifetime(service) {}
}
