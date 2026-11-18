import Foundation

/// An alarm for a watch without realtime settings, where the phone writes the alarms to the watch.
public struct WatchAlarm: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var hour: Int
    public var minute: Int
    public var isEnabled: Bool
    /// The days the alarm repeats on. Empty rings once.
    public var weekdays: Set<Weekday>
    public var sound: Sound
    public var backlight: Bool

    public init(id: UUID = UUID(), hour: Int, minute: Int, isEnabled: Bool = true, weekdays: Set<Weekday> = [],
                sound: Sound = .tone, backlight: Bool = false) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
        self.weekdays = weekdays
        self.sound = sound
        self.backlight = backlight
    }

    /// Raw values are the FIT tone codes.
    public enum Sound: Int, Sendable, Codable, CaseIterable {
        case off = 0, tone = 1, vibration = 2, toneAndVibration = 3
    }

    /// Raw values count from Monday, so each day is one bit of the watch's repeat mask (Monday 1 up to Sunday 64).
    public enum Weekday: Int, Sendable, Codable, CaseIterable {
        case monday, tuesday, wednesday, thursday, friday, saturday, sunday

        public var bit: UInt32 { 1 << rawValue }
    }
}
