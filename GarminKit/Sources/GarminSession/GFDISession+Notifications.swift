import Foundation
import GarminCore
import GarminModels
import GarminProtocol

// Notifications the app originates (GNCS), as Gadgetbridge does them. iPhone notifications are not handled here: the
// watch reads those itself over ANCS once the link is bonded, so the app never forwards them and nothing shows twice.
//
// The subscription reply says the app sends notifications (Gadgetbridge's default). That flag covers only GNCS. It
// does not change ANCS, and the device settings the app sends contain nothing about notifications.

extension GFDISession {
    /// Gadgetbridge's NotificationAction codes. Positive actions use 1 to 5, in the order the app lists them. Dismiss is 98.
    enum ActionCode {
        static let dismiss: UInt8 = 98
        static let maxPositive = 5
    }

    /// Gadgetbridge's notification id for the sync summary. Every sync replaces the previous summary.
    static let syncNotificationID: Int32 = 1

    func sendNotification(_ notification: PhoneNotification) async throws {
        let key = Int32(truncatingIfNeeded: notification.id)
        let kind: GFDINotificationUpdate.Kind = notifications[key] == nil ? .add : .modify
        notifications[key] = notification
        try await transmit(update(kind, key, notification))
    }

    /// Removes a notification from the watch. The watch asks for its text no more after this.
    func removeNotification(_ key: Int32) async {
        guard let notification = notifications.removeValue(forKey: key) else { return }
        await send(update(.remove, key, notification))
    }

    /// Announces the activities a sync imported, so the watch shows them like any other notification.
    func notifySyncedActivities(_ count: Int) async {
        let title = count == 1 ? "1 new activity" : "\(count) new activities"
        try? await sendNotification(PhoneNotification(
            id: Int(Self.syncNotificationID), appIdentifier: "OpenGarmin", title: title, body: "Synced from your watch",
            date: .now, category: .healthAndFitness
        ))
    }

    /// NOTIFICATION_UPDATE for a notification. The count covers the notifications of the same category, as Gadgetbridge's does.
    private func update(_ kind: GFDINotificationUpdate.Kind, _ key: Int32,
                        _ notification: PhoneNotification) -> GFDINotificationUpdate {
        let sameCategory = notifications.values.filter { $0.category == notification.category }.count
        return GFDINotificationUpdate(
            kind: kind,
            // Gadgetbridge always sets ACTION_DECLINE, even though only legacy actions need it.
            flags: [.foreground, .actionDecline],
            category: GFDINotificationUpdate.Category(rawValue: notification.category.rawValue) ?? .other,
            count: UInt8(min(sameCategory, 255)),
            notificationID: key,
            phoneFlags: notification.actions.isEmpty ? [] : [.newActions]
        )
    }

    /// The watch asks for the text of a notification it was told about, or acts on one. Attribute requests are answered
    /// with NOTIFICATION_DATA. A dismiss removes the notification from the watch, and a positive action is reported.
    func receiveNotificationControl(_ message: GFDINotificationControl) async {
        await send(message.acknowledgement())
        switch message.request {
        case let .notificationAttributes(id, attributes):
            guard let notification = notifications[id] else { return }
            await sendAttributes(id, attributes, of: notification)
        case let .action(id, actionID, _):
            await performAction(id, actionID: actionID)
        case .legacyAction, .appAttributes:
            break
        }
    }

    private func performAction(_ key: Int32, actionID: UInt8) async {
        guard let notification = notifications[key] else { return }
        if actionID == ActionCode.dismiss {
            await removeNotification(key)
            return
        }
        let positive = Self.positiveActions(notification.actions)
        let slot = Int(actionID) - 1
        guard positive.indices.contains(slot) else { return }
        output(.event(.notificationAction(id: notification.id, actionIndex: positive[slot].offset)))
    }

    /// Writes the requested attributes as one NOTIFICATION_DATA transfer. The message size goes last, as Gadgetbridge sends it.
    private func sendAttributes(_ key: Int32, _ attributes: [GFDINotificationAttributeRequest],
                                of notification: PhoneNotification) async {
        var writer = ByteWriter()
        writer.writeUInt8(0) // GET_NOTIFICATION_ATTRIBUTES
        writer.writeInt32(key)
        let ordered = attributes.filter { $0.attribute != .messageSize } + attributes.filter { $0.attribute == .messageSize }
        for requested in ordered {
            var value = Self.attributeBytes(requested.attribute, of: notification)
            if requested.maxLength > 0 { value = Array(value.prefix(Int(requested.maxLength))) }
            writer.writeUInt8(requested.attribute.rawValue)
            writer.writeUInt16(UInt16(value.count))
            writer.writeBytes(value)
        }
        let bytes = writer.bytes
        var crc: UInt16 = 0
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 200, bytes.count)
            crc = GarminCRC.compute(bytes[offset..<end], seed: crc)
            await send(GFDINotificationData(messageSize: UInt16(bytes.count), crc: crc,
                                            dataOffset: UInt16(offset), chunk: Data(bytes[offset..<end])))
            offset = end
        }
    }

    /// The positive actions the watch can choose, with their index into `actions`. Only the first five are shown.
    private static func positiveActions(_ actions: [PhoneNotificationAction]) -> [(offset: Int, element: PhoneNotificationAction)] {
        Array(actions.enumerated().filter { !$0.element.isNegative }.prefix(ActionCode.maxPositive))
    }

    private static func attributeBytes(_ attribute: GFDINotificationAttribute, of notification: PhoneNotification) -> [UInt8] {
        switch attribute {
        case .appIdentifier: Array(notification.appIdentifier.utf8)
        case .title: Array(notification.title.utf8)
        case .subtitle: Array((notification.subtitle ?? "").utf8)
        case .message: Array(notification.body.utf8)
        case .messageSize: Array(String(notification.body.utf8.count).utf8)
        case .date: Array(garminDate(notification.date).utf8)
        case .negativeActionLabel: Array((notification.actions.first { $0.isNegative }?.title ?? "").utf8)
        case .actions: actionsBytes(notification.actions)
        case .attachments: Array("0".utf8)
        }
    }

    /// Gadgetbridge's date format for the DATE attribute, in the local time zone.
    private static func garminDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    /// The ACTIONS attribute: a count, then for each action its code, icon position bits, and a length-prefixed title.
    /// Positive actions get codes 1 to 5, and the first negative action dismisses. An empty list is four zero bytes, as in Gadgetbridge.
    private static func actionsBytes(_ actions: [PhoneNotificationAction]) -> [UInt8] {
        var items: [[UInt8]] = []
        var positive = 0
        for action in actions {
            let code: UInt8
            let iconPosition: UInt8
            if action.isNegative {
                guard !items.contains(where: { $0[0] == ActionCode.dismiss }) else { continue }
                code = ActionCode.dismiss
                iconPosition = 0b100 // Gadgetbridge's LEFT
            } else {
                guard positive < ActionCode.maxPositive else { continue }
                positive += 1
                code = UInt8(positive)
                iconPosition = 0
            }
            let title = Array(action.title.utf8.prefix(255))
            items.append([code, iconPosition, UInt8(title.count)] + title)
        }
        guard !items.isEmpty else { return [0, 0, 0, 0] }
        return [UInt8(items.count)] + items.flatMap { $0 }
    }
}
