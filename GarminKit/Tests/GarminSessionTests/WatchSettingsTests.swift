import Foundation
import Testing
import GarminCore
import GarminFIT
import GarminModels
import GarminProtobuf
import GarminProtocol
@testable import GarminSession

/// A realtime settings message, carried in one PROTOBUF_RESPONSE.
@MainActor
private func settingsResponse(_ service: GarminVivomovehr_RealtimeSettingsService) -> GFDIFrame {
    var smart = GarminVivomovehr_Smart()
    smart.realtimeSettingsService = service
    let bytes = try! smart.serializedData()
    return GFDIProtobufResponse(chunk: GFDIProtobufChunk(requestID: 1, dataOffset: 0, totalLength: UInt32(bytes.count),
                                                         data: bytes)).frame()
}

/// The realtime settings request in a PROTOBUF_REQUEST frame the phone wrote, if it is one.
@MainActor
private func settingsRequest(_ frame: GFDIFrame) -> GarminVivomovehr_RealtimeSettingsService? {
    guard frame.messageType == GFDIMessageID.protobufRequest.rawValue,
          let request = try? GFDIProtobufRequest(frame: frame),
          let smart = try? GarminVivomovehr_Smart(serializedBytes: request.chunk.data),
          smart.hasRealtimeSettingsService else { return nil }
    return smart.realtimeSettingsService
}

/// Screen 36352 as a watch with a switch, a list and a hidden entry describes it, with its state.
@MainActor
private func rootScreenReply(_ frame: GFDIFrame) -> [GFDIFrame] {
    guard let asked = settingsRequest(frame) else { return [] }
    var service = GarminVivomovehr_RealtimeSettingsService()
    if asked.hasDefinitionRequest {
        var definition = GarminVivomovehr_ScreenDefinition()
        definition.screenID = asked.definitionRequest.screenID
        definition.title.text = "Settings"

        var toggle = GarminVivomovehr_ScreenEntry()
        toggle.id = 1
        toggle.rowType = .rowSwitch
        toggle.title.text = "Do not disturb"

        var list = GarminVivomovehr_ScreenEntry()
        list.id = 2
        list.rowType = .rowSingleLine
        list.title.text = "Backlight"
        list.target.type = .list
        for title in ["Off", "On"] {
            var option = GarminVivomovehr_TargetOptionEntry()
            option.title.text = title
            list.target.options.option.append(option)
        }

        var hidden = GarminVivomovehr_ScreenEntry()
        hidden.id = 3
        hidden.rowType = .rowNotice
        hidden.title.text = "Hidden"

        definition.entry = [toggle, list, hidden]
        var response = GarminVivomovehr_ScreenDefinitionResponse()
        response.definition = definition
        service.definitionResponse = response
    } else if asked.hasStateRequest {
        var on = GarminVivomovehr_EntryState()
        on.id = 1
        on.state = 0
        on.`switch`.enabled = true
        on.`switch`.title.text = "On"

        var index = GarminVivomovehr_EntryState()
        index.id = 2
        index.state = 0
        index.summary.valueList.index = 1

        var hidden = GarminVivomovehr_EntryState()
        hidden.id = 3
        hidden.state = 1

        var state = GarminVivomovehr_ScreenState()
        state.screenID = asked.stateRequest.screenID
        state.state = [on, index, hidden]
        var response = GarminVivomovehr_ScreenStateResponse()
        response.state = state
        service.stateResponse = response
    } else {
        return []
    }
    return [settingsResponse(service)]
}

@MainActor
private func settingsSession(_ link: FakeLink) throws -> (session: GFDISession, pump: Task<Void, Never>) {
    let store = try makeStore()
    let session = GFDISession(link: link, store: store, capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { _ in }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    return (session, pump)
}

@MainActor
@Test func settingsScreenRoundTripBuildsTheRowsWithTheirState() async throws {
    let link = FakeLink()
    link.reply = rootScreenReply
    let (session, pump) = try settingsSession(link)
    defer { pump.cancel() }

    let screen = try await session.readSettingsScreen(WatchSettingsScreen.rootID)

    // The hidden entry is left out. The switch shows its title as the summary, and the list shows the index the watch set.
    #expect(screen == WatchSettingsScreen(id: 36352, title: "Settings", rows: [
        WatchSettingsRow(id: "1", entryID: 1, title: "Do not disturb", summary: "On", isEnabled: true,
                         control: .toggle(isOn: true)),
        WatchSettingsRow(id: "2", entryID: 2, title: "Backlight", summary: nil, isEnabled: true,
                         control: .choice(options: ["Off", "On"], selected: 1)),
    ]))
    // The phone asked for the definition and the state of the screen, in that order.
    let asked = try link.framesSent(of: .protobufRequest).map { frame -> GarminVivomovehr_RealtimeSettingsService in
        try #require(settingsRequest(frame))
    }
    #expect(asked.map { $0.hasDefinitionRequest } == [true, false])
    #expect(asked.map { $0.hasStateRequest } == [false, true])
}

/// A watch that accepts a change request and says whether the phone should leave the screen.
@MainActor
private func acceptsChange(leave: Bool) -> @MainActor @Sendable (GFDIFrame) -> [GFDIFrame] {
    { frame in
        guard let asked = settingsRequest(frame), asked.hasChangeRequest else { return [] }
        var response = GarminVivomovehr_ChangeResponse()
        response.status = .success
        response.shouldReturn = leave
        var service = GarminVivomovehr_RealtimeSettingsService()
        service.changeResponse = response
        return [settingsResponse(service)]
    }
}

@MainActor
@Test func settingChangeSendsTheChangeRequestBytesAndReturnsTheWatchOutcome() async throws {
    let link = FakeLink()
    link.reply = acceptsChange(leave: false)
    let (session, pump) = try settingsSession(link)
    defer { pump.cancel() }

    // Smart field 42 (realtime settings), RealtimeSettingsService field 5 (change request), screen 1, entry 2,
    // switch field 3 with value true. Written out by hand from the protobuf wire format.
    let outcome = try await session.changeSetting(screenID: 1, entryID: 2, .toggle(true))
    #expect(outcome == .refresh)
    let sent = try #require(link.framesSent(of: .protobufRequest).last)
    let expected = try #require(Data(hex: "d2020a2a08080110021a020801"))
    #expect(try GFDIProtobufRequest(frame: sent).chunk.data == expected)

    link.reply = acceptsChange(leave: true)
    let leave = try await session.changeSetting(screenID: 1, entryID: 2, .toggle(false))
    #expect(leave == .leave)
}

@MainActor
@Test func alarmsEncodeAsGadgetbridgeSettingsFile() throws {
    let alarms = [
        WatchAlarm(hour: 6, minute: 40, weekdays: [.monday, .friday]),
        WatchAlarm(hour: 7, minute: 5, isEnabled: false, sound: .vibration),
    ]
    let file = try FitDecoder.decode(AlarmFitEncoder.encode(alarms, now: Date(timeIntervalSince1970: 1_800_000_000)))

    // FILE_ID: a settings file (type 2).
    #expect(file.messages(0).first?[0]?.int == 2)

    // ALARM_SETTINGS per alarm: minute of day, repeat mask (Monday 1 + Friday 16, or 128 for a single ring), enabled,
    // sound (vibration is 2).
    let alarmMessages = file.messages(222)
    #expect(alarmMessages.count == 2)
    #expect(alarmMessages.map { $0[0]?.int } == [400, 425])
    #expect(alarmMessages.map { $0[1]?.int } == [17, 128])
    #expect(alarmMessages.map { $0[2]?.int } == [1, 0])
    #expect(alarmMessages[1][3]?.int == 2)

    // DEVICE_SETTINGS lists them: times, custom mode (5) each, enabled flags, repeat masks.
    let device = try #require(file.messages(2).first)
    #expect(elements(device[8]) == [400, 425])
    #expect(elements(device[9]) == [5, 5])
    #expect(elements(device[28]) == [1, 0])
    #expect(elements(device[92]) == [17, 128])
}

@MainActor
@Test func disabledAlarmsOnlyWriteTheFileIdAndAlarms() throws {
    let file = try FitDecoder.decode(AlarmFitEncoder.encode([WatchAlarm(hour: 1, minute: 0, isEnabled: false)]))
    #expect(file.messages(222).count == 1)
    #expect(file.messages(2).isEmpty)
}

private func elements(_ value: FitValue?) -> [Int64?] {
    guard case let .array(values)? = value else { return [] }
    return values.map(\.int)
}
