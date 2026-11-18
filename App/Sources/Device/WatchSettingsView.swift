import SwiftUI
import GarminModels

/// One settings screen the watch defines, rendered natively. The watch sends the menu tree, so sub-screens open as
/// their own view. Every change goes to the watch, which answers whether the screen should be read again or left.
struct WatchSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    let screenID: UInt32
    let fallbackTitle: String
    @State private var screen: WatchSettingsScreen?
    @State private var loadError: String?
    @State private var isChanging = false
    @State private var problem: String?

    var body: some View {
        Group {
            if let screen {
                form(screen)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't load settings", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(screen?.title ?? fallbackTitle)
        .task { await load() }
        .alert("Couldn't change the setting", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } })
        ) {} message: {
            Text(problem ?? "")
        }
    }

    private func form(_ screen: WatchSettingsScreen) -> some View {
        Form {
            ForEach(Self.sections(screen.rows)) { section in
                Section {
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .disabled(isChanging)
    }

    @ViewBuilder
    private func rowView(_ row: WatchSettingsRow) -> some View {
        switch row.control {
        case .category, .space:
            EmptyView()
        case .notice:
            Text(row.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .subscreen(id):
            NavigationLink {
                WatchSettingsView(screenID: id, fallbackTitle: row.title)
            } label: {
                LabeledContent(row.title, value: row.summary ?? "")
            }
            .disabled(!row.isEnabled)
        case .action:
            Button(row.title) { change(row, .action) }
                .disabled(!row.isEnabled)
        case let .toggle(isOn):
            Toggle(row.title, isOn: Binding(get: { isOn }, set: { change(row, .toggle($0)) }))
                .disabled(!row.isEnabled)
        case let .choice(options, selected):
            Picker(row.title, selection: Binding(get: { selected ?? -1 }, set: { change(row, .choice($0)) })) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index]).tag(index)
                }
            }
            .disabled(!row.isEnabled)
        case let .time(seconds):
            DatePicker(row.title, selection: Binding(
                get: { Self.date(secondsOfDay: seconds) },
                set: { change(row, .time(seconds: Self.secondsOfDay($0))) }
            ), displayedComponents: .hourAndMinute)
            .disabled(!row.isEnabled)
        case let .date(current, minimum, maximum):
            DatePicker(row.title, selection: Binding(
                get: { Calendar.current.date(from: current) ?? .now },
                set: { change(row, .date(Calendar.current.dateComponents([.year, .month, .day], from: $0))) }
            ), in: (Self.calendarDate(minimum) ?? .distantPast)...(Self.calendarDate(maximum) ?? .distantFuture),
            displayedComponents: .date)
            .disabled(!row.isEnabled)
        case let .integer(value, range, unit):
            WatchValueRow(title: row.title, unit: unit, value: "\(value)", keyboard: .numberPad,
                          isEnabled: row.isEnabled) { draft in
                guard let number = Int(draft), range.contains(number) else {
                    return reject("Enter a whole number from \(range.lowerBound) to \(range.upperBound).")
                }
                change(row, .integer(number))
            }
        case let .decimal(value, range, unit):
            WatchValueRow(title: row.title, unit: unit, value: Self.decimalText(value), keyboard: .decimalPad,
                          isEnabled: row.isEnabled) { draft in
                guard let number = Double(draft.replacingOccurrences(of: ",", with: ".")), range.contains(number) else {
                    return reject("Enter a number from \(Self.decimalText(range.lowerBound)) to \(Self.decimalText(range.upperBound)).")
                }
                change(row, .decimal(number))
            }
        case let .duration(seconds, range):
            WatchValueRow(title: row.title, unit: "seconds", value: "\(seconds)", keyboard: .numberPad,
                          isEnabled: row.isEnabled) { draft in
                guard let number = Int(draft), range.contains(number) else {
                    return reject("Enter a number of seconds from \(range.lowerBound) to \(range.upperBound).")
                }
                change(row, .duration(seconds: number))
            }
        case let .height(value, unit):
            WatchValueRow(title: row.title, unit: unit == 0 ? "cm" : "in", value: "\(value)", keyboard: .numberPad,
                          isEnabled: row.isEnabled) { draft in
                guard let number = Int(draft), number > 0 else { return reject("Enter a height above zero.") }
                change(row, .height(value: number, unit: unit))
            }
        case let .text(maxLength):
            WatchValueRow(title: row.title, unit: nil, value: row.summary ?? "", keyboard: .default,
                          isEnabled: row.isEnabled) { draft in
                guard !draft.isEmpty else { return }
                if let maxLength, draft.count > maxLength {
                    return reject("Use at most \(maxLength) characters.")
                }
                change(row, .text(draft))
            }
        case let .position(index, count):
            HStack {
                Text(row.title)
                Spacer()
                Menu {
                    if index > 0 {
                        Button("Move up") { change(row, .move(to: index - 1)) }
                    }
                    if index < count - 1 {
                        Button("Move down") { change(row, .move(to: index + 1)) }
                    }
                    Button("Delete", role: .destructive) { change(row, .delete) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .disabled(!row.isEnabled)
        }
    }

    private func change(_ row: WatchSettingsRow, _ value: WatchSettingChange) {
        guard !isChanging else { return }
        Task {
            isChanging = true
            defer { isChanging = false }
            do {
                switch try await app.watch.changeSetting(screen: screenID, entryID: row.entryID, value) {
                case .leave: dismiss()
                case .refresh: await load()
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func reject(_ message: String) {
        problem = message
    }

    private func load() async {
        do {
            screen = try await app.watch.settingsScreen(screenID)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private struct SettingsSection: Identifiable {
        let id: Int
        var title: String?
        var rows: [WatchSettingsRow]
    }

    /// Splits the rows at each category heading and space, so each part becomes one section.
    private static func sections(_ rows: [WatchSettingsRow]) -> [SettingsSection] {
        var sections = [SettingsSection(id: 0, title: nil, rows: [])]
        for row in rows {
            switch row.control {
            case .category:
                sections.append(SettingsSection(id: sections.count, title: row.title, rows: []))
            case .space:
                sections.append(SettingsSection(id: sections.count, title: nil, rows: []))
            default:
                sections[sections.count - 1].rows.append(row)
            }
        }
        return sections.filter { !$0.rows.isEmpty }
    }

    private static func date(secondsOfDay seconds: Int) -> Date {
        Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(seconds))
    }

    private static func secondsOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60
    }

    private static func calendarDate(_ parts: DateComponents?) -> Date? {
        parts.flatMap { Calendar.current.date(from: $0) }
    }

    private static func decimalText(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }
}

/// A row whose value the user types. The value is sent when the field loses focus, and only if it changed.
private struct WatchValueRow: View {
    let title: String
    let unit: String?
    let value: String
    let keyboard: UIKeyboardType
    let isEnabled: Bool
    let onCommit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(title: String, unit: String?, value: String, keyboard: UIKeyboardType, isEnabled: Bool,
         onCommit: @escaping (String) -> Void) {
        self.title = title
        self.unit = unit
        self.value = value
        self.keyboard = keyboard
        self.isEnabled = isEnabled
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", text: $draft)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(keyboard)
                    .focused($focused)
                    .onSubmit { focused = false }
                if let unit {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!isEnabled)
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onChange(of: value) { _, newValue in
            draft = newValue
        }
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
    }
}
