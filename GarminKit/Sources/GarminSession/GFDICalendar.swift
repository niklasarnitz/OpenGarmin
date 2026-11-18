import Foundation
import GarminModels
import GarminProtobuf

/// Answers the watch's calendar requests from the events the phone pushed. Follows Gadgetbridge's
/// ProtocolBufferHandler: times are Unix seconds on the wire, the request range is compared in the same unit,
/// and text is cut to the lengths the request asks for.
enum GFDICalendar {
    static func response(to calendar: GDI_Proto_Calendar_CalendarService, events: [CalendarEvent]) -> GarminVivomovehr_Smart {
        var response = GDI_Proto_Calendar_CalendarEventsResponse()
        if calendar.hasCalendarEventsRequest {
            response.status = .ok
            response.events = watchEvents(for: calendar.calendarEventsRequest, events: events)
        } else {
            response.status = .unknownResponseStatus
        }
        var service = GDI_Proto_Calendar_CalendarService()
        service.calendarEventsResponse = response
        var smart = GarminVivomovehr_Smart()
        smart.calendarEventsService = service
        return smart
    }

    /// The events that overlap the requested range, oldest first, up to twice the watch's maximum.
    private static func watchEvents(for request: GDI_Proto_Calendar_CalendarEventsRequest, events: [CalendarEvent]) -> [GDI_Proto_Calendar_CalendarEvent] {
        let limit = Int(request.maxEvents) * 2
        var items: [GDI_Proto_Calendar_CalendarEvent] = []
        for event in events.sorted(by: { $0.start < $1.start }) {
            guard items.count < limit else { break }
            let start = unixSeconds(event.start)
            let end = unixSeconds(event.end)
            guard end >= request.startDate, start <= request.endDate else { continue }
            guard request.includeAllDay || !event.isAllDay else { continue }

            var item = GDI_Proto_Calendar_CalendarEvent()
            item.title = String(event.title.prefix(Int(request.maxTitleLength)))
            item.startDate = start
            item.endDate = end
            item.allDay = event.isAllDay
            if request.includeLocation, let location = event.location {
                item.location = String(location.prefix(Int(request.maxLocationLength)))
            }
            if request.includeDescription, let notes = event.notes {
                item.description_p = String(notes.prefix(Int(request.maxDescriptionLength)))
            }
            items.append(item)
        }
        return items
    }

    private static func unixSeconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970))
    }
}
