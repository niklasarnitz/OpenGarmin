import SwiftUI
import GarminModels

/// Alarms for a watch without realtime settings. The app keeps the list and sends it as a settings file, which
/// replaces the watch's alarms.
struct WatchAlarmsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var alarms: [WatchAlarm] = WatchAlarmStore.load()
    @State private var isSending = false
    @State private var sentCount = 0
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                ForEach($alarms) { $alarm in
                    WatchAlarmEditor(alarm: $alarm)
                }
                .onDelete { alarms.remove(atOffsets: $0) }
            } footer: {
                Text("The watch has \(app.watch.alarmSlots) alarm slots. Changes reach the watch when you tap Send to watch.")
            }
            Section {
                Button("Add alarm", systemImage: "plus") {
                    alarms.append(WatchAlarm(hour: 7, minute: 0))
                }
                .disabled(alarms.count >= app.watch.alarmSlots)
                Button("Send to watch", systemImage: "paperplane.fill") { send() }
                    .disabled(isSending)
            }
        }
        .navigationTitle("Alarms")
        .onChange(of: alarms) { _, new in WatchAlarmStore.save(new) }
        .sensoryFeedback(.success, trigger: sentCount)
        .alert("Couldn't send the alarms", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } })
        ) {} message: {
            Text(problem ?? "")
        }
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await app.watch.setAlarms(alarms)
                sentCount += 1
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The alarms are kept on the phone between launches, as JSON in the standard defaults.
enum WatchAlarmStore {
    private static let key = "watch.alarms"

    static func load() -> [WatchAlarm] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([WatchAlarm].self, from: $0) } ?? []
    }

    static func save(_ alarms: [WatchAlarm]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(alarms), forKey: key)
    }
}

private struct WatchAlarmEditor: View {
    @Binding var alarm: WatchAlarm
    private static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                Toggle("On", isOn: $alarm.isEnabled)
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                ForEach(WatchAlarm.Weekday.allCases, id: \.self) { day in
                    let isOn = alarm.weekdays.contains(day)
                    Button(Self.dayLetters[day.rawValue]) {
                        if isOn { alarm.weekdays.remove(day) } else { alarm.weekdays.insert(day) }
                    }
                    .buttonStyle(.bordered)
                    .tint(isOn ? Palette.lichen : .secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            Text(alarm.weekdays.isEmpty ? "Rings once" : "Repeats on the selected days")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Sound", selection: $alarm.sound) {
                Text("Off").tag(WatchAlarm.Sound.off)
                Text("Tone").tag(WatchAlarm.Sound.tone)
                Text("Vibration").tag(WatchAlarm.Sound.vibration)
                Text("Tone and vibration").tag(WatchAlarm.Sound.toneAndVibration)
            }
            Toggle("Backlight", isOn: $alarm.backlight)
        }
        .padding(.vertical, 4)
    }

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: .now) ?? .now },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                alarm.hour = parts.hour ?? 0
                alarm.minute = parts.minute ?? 0
            }
        )
    }
}
