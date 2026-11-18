import Foundation

/// One settings screen the watch defines: its rows, in the order the watch lists them. The watch defines the menu tree,
/// so the app renders whatever screens it asks for. Gadgetbridge opens the tree at `rootID`.
public struct WatchSettingsScreen: Sendable, Equatable {
    /// The screen the watch's settings menu starts from.
    public static let rootID: UInt32 = 36352

    public var id: UInt32
    public var title: String?
    public var rows: [WatchSettingsRow]

    public init(id: UInt32, title: String?, rows: [WatchSettingsRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// A row of a settings screen. `id` is unique within the screen for SwiftUI; `entryID` is the watch's id for the row,
/// which the change requests name.
public struct WatchSettingsRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var entryID: UInt32
    public var title: String
    /// The watch's text for the current value, such as "On" or "15 seconds".
    public var summary: String?
    /// The watch can grey a row out. Disabled rows show their value but do not take changes.
    public var isEnabled: Bool
    public var control: Control

    public init(id: String, entryID: UInt32, title: String, summary: String?, isEnabled: Bool, control: Control) {
        self.id = id
        self.entryID = entryID
        self.title = title
        self.summary = summary
        self.isEnabled = isEnabled
        self.control = control
    }

    public enum Control: Sendable, Equatable {
        /// A heading that starts a new section of the screen.
        case category
        /// A gap that starts a new section without a heading.
        case space
        /// Text the watch shows with no action.
        case notice
        /// A screen of its own, opened by the row.
        case subscreen(UInt32)
        /// A row whose tap makes the watch do something, with no value.
        case action
        case toggle(isOn: Bool)
        /// Options by index. `selected` is nil when the watch has no value set.
        case choice(options: [String], selected: Int?)
        /// A time of day, in seconds since midnight.
        case time(seconds: Int)
        case date(current: DateComponents, minimum: DateComponents?, maximum: DateComponents?)
        case integer(value: Int, range: ClosedRange<Int>, unit: String?)
        case decimal(value: Double, range: ClosedRange<Double>, unit: String?)
        case duration(seconds: Int, range: ClosedRange<Int>)
        /// A height. `unit` is the watch's code, where 0 is centimetres.
        case height(value: Int, unit: UInt32)
        /// Free text, up to `maxLength` characters when the watch sets a limit.
        case text(maxLength: Int?)
        /// One item of a list the watch lets the user reorder and delete from, at `index` of `count` items.
        case position(index: Int, count: Int)
    }
}

/// A value the app sends for a row. The row's `entryID` and its screen's id go with it.
public enum WatchSettingChange: Sendable, Equatable {
    case toggle(Bool)
    case choice(Int)
    case time(seconds: Int)
    case date(DateComponents)
    case integer(Int)
    case decimal(Double)
    case duration(seconds: Int)
    case height(value: Int, unit: UInt32)
    case text(String)
    case action
    /// Moves a list item to `index`.
    case move(to: Int)
    case delete
}

/// What the app does after the watch accepts a change: the watch may send the user back to the previous screen.
public enum WatchSettingsOutcome: Sendable, Equatable {
    case refresh
    case leave
}
