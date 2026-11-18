import Foundation
import GarminModels
import GarminProtobuf

/// A settings screen read in flight. The watch answers the screen's definition and its state in two messages.
struct SettingsRead {
    let id = UUID()
    let screenID: UInt32
    var definition: GarminVivomovehr_ScreenDefinition?
    var state: GarminVivomovehr_ScreenState?
    let continuation: CheckedContinuation<WatchSettingsScreen, Error>
}

/// A settings change in flight, answered by a change response.
struct SettingsChange {
    let id = UUID()
    let continuation: CheckedContinuation<WatchSettingsOutcome, Error>
}

// Realtime settings, as Gadgetbridge's GarminSupport and GarminRealtimeSettingsFragment do them: the phone asks for a
// screen's definition and state, the watch sends the menu tree, and a change request is answered with a change response
// that says whether the phone should refresh the screen or leave it.

extension GFDISession {
    private static let settingsTimeout: Duration = .seconds(10)

    /// Gadgetbridge's init request: the phone's language and a fixed region. Sent once the watch has the realtime settings.
    func initSettings() async {
        var request = GarminVivomovehr_InitRequest()
        request.language = Self.localeIdentifier
        request.region = "us"
        var service = GarminVivomovehr_RealtimeSettingsService()
        service.initRequest = request
        try? await sendProtobufRequest(Self.settings(service))
    }

    /// Reads one settings screen: its definition and its current state.
    func readSettingsScreen(_ screenID: UInt32) async throws -> WatchSettingsScreen {
        guard settingsRead == nil else { throw GarminWatchError.busy }
        return try await withCheckedThrowingContinuation { continuation in
            let read = SettingsRead(screenID: screenID, continuation: continuation)
            settingsRead = read
            Task {
                do {
                    try await sendProtobufRequest(Self.definitionRequest(screenID))
                    try await sendProtobufRequest(Self.stateRequest(screenID))
                } catch {
                    failSettingsRead(read.id, error)
                }
            }
            Task {
                try? await Task.sleep(for: Self.settingsTimeout)
                failSettingsRead(read.id, GarminWatchError.timedOut)
            }
        }
    }

    /// Sends one change to a settings entry. The watch answers with whether the screen should be read again.
    func changeSetting(screenID: UInt32, entryID: UInt32, _ change: WatchSettingChange) async throws -> WatchSettingsOutcome {
        guard settingsChange == nil else { throw GarminWatchError.busy }
        var request = GarminVivomovehr_ChangeRequest()
        request.screenID = screenID
        request.entryID = entryID
        Self.apply(change, to: &request)
        var service = GarminVivomovehr_RealtimeSettingsService()
        service.changeRequest = request
        let smart = Self.settings(service)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = SettingsChange(continuation: continuation)
            settingsChange = pending
            Task {
                do {
                    try await sendProtobufRequest(smart)
                } catch {
                    failSettingsChange(pending.id, error)
                }
            }
            Task {
                try? await Task.sleep(for: Self.settingsTimeout)
                failSettingsChange(pending.id, GarminWatchError.timedOut)
            }
        }
    }

    /// Fails the read and the change in flight, when the link drops.
    func failSettings(_ error: Error) {
        if let read = settingsRead {
            settingsRead = nil
            read.continuation.resume(throwing: error)
        }
        if let change = settingsChange {
            settingsChange = nil
            change.continuation.resume(throwing: error)
        }
    }

    /// Routes the watch's realtime settings messages to the read or the change in flight.
    func receiveRealtimeSettings(_ service: GarminVivomovehr_RealtimeSettingsService) {
        if service.hasDefinitionResponse, let read = settingsRead {
            let response = service.definitionResponse
            if response.status != 0 {
                failSettingsRead(read.id, GarminWatchError.unsupported("The watch has no settings screen \(read.screenID)."))
            } else if response.definition.screenID == read.screenID {
                settingsRead?.definition = response.definition
            }
        }
        if service.hasStateResponse, settingsRead?.screenID == service.stateResponse.state.screenID {
            settingsRead?.state = service.stateResponse.state
        }
        if let read = settingsRead, let definition = read.definition, let state = read.state {
            settingsRead = nil
            read.continuation.resume(returning: WatchSettingsScreen.make(definition, state: state))
        }
        if service.hasChangeResponse, let change = settingsChange {
            settingsChange = nil
            let response = service.changeResponse
            if response.status == .success {
                change.continuation.resume(returning: response.shouldReturn ? .leave : .refresh)
            } else {
                change.continuation.resume(throwing: GarminWatchError.unsupported("The watch refused the change."))
            }
        }
    }

    private func failSettingsRead(_ id: UUID, _ error: Error) {
        guard let read = settingsRead, read.id == id else { return }
        settingsRead = nil
        read.continuation.resume(throwing: error)
    }

    private func failSettingsChange(_ id: UUID, _ error: Error) {
        guard let change = settingsChange, change.id == id else { return }
        settingsChange = nil
        change.continuation.resume(throwing: error)
    }

    private static func settings(_ service: GarminVivomovehr_RealtimeSettingsService) -> GarminVivomovehr_Smart {
        var smart = GarminVivomovehr_Smart()
        smart.realtimeSettingsService = service
        return smart
    }

    /// The phone's locale as Gadgetbridge sends it (language_REGION), or en_US when it does not have that shape.
    private static var localeIdentifier: String {
        let locale = Locale.current
        let identifier = "\(locale.language.languageCode?.identifier ?? "en")_\(locale.region?.identifier ?? "US")"
        return identifier.count == 5 ? identifier : "en_US"
    }

    private static func definitionRequest(_ screenID: UInt32) -> GarminVivomovehr_Smart {
        var request = GarminVivomovehr_ScreenDefinitionRequest()
        request.screenID = screenID
        request.unk2 = 0
        request.locale = localeIdentifier
        var service = GarminVivomovehr_RealtimeSettingsService()
        service.definitionRequest = request
        return settings(service)
    }

    private static func stateRequest(_ screenID: UInt32) -> GarminVivomovehr_Smart {
        var request = GarminVivomovehr_ScreenStateRequest()
        request.screenID = screenID
        var service = GarminVivomovehr_RealtimeSettingsService()
        service.stateRequest = request
        return settings(service)
    }

    /// Writes the change into the request field its kind uses, as Gadgetbridge's fragment does.
    private static func apply(_ change: WatchSettingChange, to request: inout GarminVivomovehr_ChangeRequest) {
        switch change {
        case let .toggle(isOn):
            var value = GarminVivomovehr_ChangeRequest.Switch()
            value.value = isOn
            request.`switch` = value
        case let .choice(index):
            var option = GarminVivomovehr_ChangeRequest.Option()
            option.index = UInt32(index)
            request.option = option
        case let .time(seconds):
            var time = GarminVivomovehr_ChangeRequest.Time()
            time.seconds = UInt32(seconds)
            request.timeOfDay = time
        case let .duration(seconds):
            var time = GarminVivomovehr_ChangeRequest.Time()
            time.seconds = UInt32(seconds)
            request.duration = time
        case let .date(components):
            var date = GarminVivomovehr_Date()
            date.year = UInt32(components.year ?? 0)
            date.month = UInt32(components.month ?? 0)
            date.day = UInt32(components.day ?? 0)
            var newDate = GarminVivomovehr_ChangeRequest.NewDate()
            newDate.value = date
            request.newDate = newDate
        case let .integer(value):
            var integer = GarminVivomovehr_ChangeRequest.IntegerValue()
            integer.value = UInt32(truncatingIfNeeded: value)
            request.integerValue = integer
        case let .decimal(value):
            var float = GarminVivomovehr_ChangeRequest.FloatValue()
            float.value = Float(value)
            request.floatValue = float
        case let .height(value, unit):
            var height = GarminVivomovehr_ChangeRequest.Height()
            height.value = UInt32(truncatingIfNeeded: value)
            height.unit = unit
            request.height = height
        case let .text(value):
            var text = GarminVivomovehr_ChangeRequest.Text()
            text.value = value
            request.text = text
        case .action:
            break
        case let .move(to):
            var position = GarminVivomovehr_ChangeRequest.Position()
            position.index = UInt32(to)
            request.position = position
        case .delete:
            var position = GarminVivomovehr_ChangeRequest.Position()
            position.delete = true
            request.position = position
        }
    }
}

extension WatchSettingsScreen {
    /// The screen the watch described, with its state. Hidden entries are left out; disabled ones stay visible with
    /// their value but do not take changes. Entries the app does not know yet (activities, hidden rows) are left out too.
    static func make(_ definition: GarminVivomovehr_ScreenDefinition, state: GarminVivomovehr_ScreenState) -> WatchSettingsScreen {
        let states = Dictionary(state.state.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = definition.entry.flatMap { entry -> [WatchSettingsRow] in
            let entryState = states[entry.id]
            guard entryState?.state != 1 else { return [] }
            return makeRows(for: entry, state: entryState, isEnabled: entryState?.state != 2)
        }
        return WatchSettingsScreen(id: definition.screenID, title: nonEmpty(definition.title.text), rows: rows)
    }

    private static func makeRows(for entry: GarminVivomovehr_ScreenEntry, state: GarminVivomovehr_EntryState?,
                                 isEnabled: Bool) -> [WatchSettingsRow] {
        if entry.rowType == .rowSortableAndDeletable {
            let entries = entry.sortOptions.entries
            return entries.enumerated().map { index, sortEntry in
                WatchSettingsRow(id: "\(entry.id)-\(sortEntry.id)", entryID: sortEntry.id, title: sortEntry.title.text,
                                 summary: nil, isEnabled: isEnabled,
                                 control: .position(index: index, count: entries.count))
            }
        }
        var control: WatchSettingsRow.Control?
        if entry.hasTarget {
            control = targetControl(entry.target, summary: state?.summary)
        } else {
            switch entry.rowType {
            case .rowNotice, .rowSingleLine, .rowDoubleLine: control = .notice
            case .rowCategory: control = .category
            case .rowSpace: control = .space
            case .rowSwitch: control = .toggle(isOn: state?.`switch`.enabled ?? false)
            case .rowSingleAction, .rowAction: control = .action
            case .rowText:
                let limits = entry.textOption.limits
                control = .text(maxLength: limits.hasMaxLength ? Int(limits.maxLength) : nil)
            default: control = nil
            }
        }
        guard let control else { return [] }
        // The watch's summary wins; a switch row falls back to the text of its switch.
        let switchTitle = entry.rowType == .rowSwitch ? state?.`switch`.title.text : nil
        return [WatchSettingsRow(id: "\(entry.id)", entryID: entry.id, title: entry.title.text,
                                 summary: nonEmpty(state?.summary.title.text) ?? nonEmpty(switchTitle),
                                 isEnabled: isEnabled, control: control)]
    }

    private static func targetControl(_ target: GarminVivomovehr_Target,
                                      summary: GarminVivomovehr_Summary?) -> WatchSettingsRow.Control? {
        switch target.type {
        case .subscreen, .subscreenOptions:
            return .subscreen(target.subscreen)
        case .list:
            let options = target.options.option.map { $0.title.text }
            let selected = summary.flatMap { summary -> Int? in
                guard summary.hasValueList, summary.valueList.hasIndex, Int(summary.valueList.index) < options.count else {
                    return nil
                }
                return Int(summary.valueList.index)
            }
            return .choice(options: options, selected: selected)
        case .timeOfDay:
            return .time(seconds: Int(summary?.valueTimeOfDay.seconds ?? 0))
        case .integer:
            let picker = target.integerPicker
            let low = picker.hasMin ? Int(picker.min) : Int(Int32.min)
            let high = picker.hasMax ? Int(picker.max) : Int(Int32.max)
            return .integer(value: Int(summary?.valueInteger.value ?? 0), range: bounds(low, high),
                            unit: nonEmpty(summary?.valueInteger.unit.text))
        case .float:
            let options = target.floatOptions
            let low = options.hasMinValue ? Double(options.minValue) : 0
            let high = options.hasMaxValue ? Double(options.maxValue) : Double(Float.greatestFiniteMagnitude)
            return .decimal(value: Double(summary?.valueFloat.value ?? 0), range: bounds(low, high),
                            unit: nonEmpty(summary?.valueFloat.uom.text))
        case .duration:
            let options = target.durationOptions
            let low = options.hasMinSeconds ? Int(options.minSeconds) : 0
            let high = options.hasMaxSeconds ? Int(options.maxSeconds) : Int(UInt32.max)
            return .duration(seconds: Int(summary?.valueDuration.seconds ?? 0), range: bounds(low, high))
        case .date:
            let date = summary?.valueDate
            return .date(current: dateComponents(date?.currentDate ?? GarminVivomovehr_Date()),
                         minimum: date.flatMap { d -> DateComponents? in d.hasMinDate ? dateComponents(d.minDate) : nil },
                         maximum: date.flatMap { d -> DateComponents? in d.hasMaxDate ? dateComponents(d.maxDate) : nil })
        case .height:
            return .height(value: Int(summary?.valueHeight.value ?? 0), unit: summary?.valueHeight.unit ?? 0)
        default:
            return nil
        }
    }

    private static func dateComponents(_ date: GarminVivomovehr_Date) -> DateComponents {
        DateComponents(year: Int(date.year), month: Int(date.month), day: Int(date.day))
    }
}

private func nonEmpty(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
}

private func bounds<T: Comparable>(_ a: T, _ b: T) -> ClosedRange<T> {
    min(a, b)...max(a, b)
}
