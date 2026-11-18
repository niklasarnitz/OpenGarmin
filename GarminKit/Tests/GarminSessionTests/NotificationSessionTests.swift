import Foundation
import Testing
import GarminCore
import GarminModels
import GarminProtocol
@testable import GarminSession

@MainActor
private func notificationSession(_ link: FakeLink, output: @escaping @MainActor (GFDISessionOutput) -> Void = { _ in })
    -> (session: GFDISession, pump: Task<Void, Never>) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try! SessionStore(directory: directory, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let session = GFDISession(link: link, importer: makeImporter(store), capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil, output: output)
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    return (session, pump)
}

/// A GNCS request from the watch, as a NOTIFICATION_CONTROL frame.
private func watchControl(_ payload: [UInt8]) -> GFDIFrame {
    GFDIFrame(messageType: GFDIMessageID.notificationControl.rawValue, payload: Data(payload))
}

@MainActor
private func waitForFrames(_ link: FakeLink, _ id: GFDIMessageID, count: Int) async throws {
    for _ in 0..<500 {
        if link.framesSent(of: id).count >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("\(id) frames were not sent within 5 seconds")
}

private let reply = PhoneNotificationAction(title: "Reply")
private let ignore = PhoneNotificationAction(title: "Ignore", isNegative: true)
private let like = PhoneNotificationAction(title: "Like")

@MainActor
@Test func watchAttributeRequestGetsTheNotificationTextAsData() async throws {
    let link = FakeLink()
    let (session, pump) = notificationSession(link)
    defer { pump.cancel() }
    let notification = PhoneNotification(id: 7, appIdentifier: "OpenGarmin", title: "Hi", body: "Body text",
                                         date: .now, category: .sms, actions: [reply, ignore])

    try await session.sendNotification(notification)

    // NOTIFICATION_UPDATE: add, foreground and decline flags, SMS category, one notification, id 7, new actions.
    let update = try #require(link.framesSent(of: .notificationUpdate).last)
    #expect(Array(update.payload) == [0, 18, 12, 1, 7, 0, 0, 0, 2])

    // The watch asks for the title and the body, each with no length limit.
    link.watchSends(watchControl([0, 7, 0, 0, 0, 1, 0, 0, 3, 0, 0]))
    try await waitForFrames(link, .notificationData, count: 1)

    // NOTIFICATION_DATA: size, CRC, offset, then the attributes: command 0, id 7, title "Hi", body "Body text".
    let chunks = link.framesSent(of: .notificationData)
    #expect(chunks.count == 1)
    let frame = Array(try #require(chunks.first).payload)
    let attributes: [UInt8] = [0, 7, 0, 0, 0, 1, 2, 0, 0x48, 0x69, 3, 9, 0] + Array("Body text".utf8)
    #expect(Int(frame[0]) | Int(frame[1]) << 8 == attributes.count)
    #expect(Int(frame[4]) | Int(frame[5]) << 8 == 0)
    #expect(Array(frame[6...]) == attributes)
}

@MainActor
@Test func watchDismissRemovesTheNotificationFromTheWatch() async throws {
    let link = FakeLink()
    let (session, pump) = notificationSession(link)
    defer { pump.cancel() }
    try await session.sendNotification(PhoneNotification(id: 7, appIdentifier: "OpenGarmin", title: "Hi", body: "",
                                                         date: .now, category: .sms))

    // PERFORM_NOTIFICATION_ACTION for notification 7 with action 98, which is dismiss.
    link.watchSends(watchControl([128, 7, 0, 0, 0, 98]))
    try await waitForFrames(link, .notificationUpdate, count: 2)

    // NOTIFICATION_UPDATE: remove, same flags, SMS category, no notifications left in the category, id 7.
    let remove = try #require(link.framesSent(of: .notificationUpdate).last)
    #expect(Array(remove.payload) == [2, 18, 12, 0, 7, 0, 0, 0, 0])
}

@MainActor
@Test func positiveActionIsReportedWithItsPositionInTheActionList() async throws {
    let link = FakeLink()
    var events: [WatchEvent] = []
    let (session, pump) = notificationSession(link) { output in
        if case let .event(event) = output { events.append(event) }
    }
    defer { pump.cancel() }
    // The negative action comes first, so the watch's action 2 (the second positive one) is index 2 in the list.
    try await session.sendNotification(PhoneNotification(id: 7, appIdentifier: "OpenGarmin", title: "Hi", body: "",
                                                         date: .now, actions: [ignore, reply, like]))

    link.watchSends(watchControl([128, 7, 0, 0, 0, 2]))
    for _ in 0..<500 where events.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    guard case let .notificationAction(id, actionIndex)? = events.first else {
        Issue.record("no action event was reported")
        return
    }
    #expect(id == 7)
    #expect(actionIndex == 2)
}
