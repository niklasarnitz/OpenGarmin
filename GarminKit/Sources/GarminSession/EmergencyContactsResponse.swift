import Foundation
import GarminModels
import GarminProtobuf

/// The watch's contact list, answered for its usercontact request. Follows Gadgetbridge's ContactsInterceptor: one
/// contact per emergency contact, each with its phone number, and the same unknown fields it sends.
enum EmergencyContactsResponse {
    static func encode(_ contacts: [EmergencyContact], now: Date = .now) -> Data {
        var response = Garmin_Response()
        response.contact = contacts.map { contact in
            var phone = Garmin_Phone()
            phone.number = contact.phoneNumber
            phone.unk2 = 1
            phone.unk3 = 1
            phone.unk4 = 0
            phone.unk5 = UInt32.random(in: 65535 ..< 131_070)
            phone.unk6 = 0
            phone.unk7 = 0
            phone.unk8 = ""
            phone.unk9 = 1
            phone.id = UUID().uuidString
            phone.unk11 = 1
            phone.unk12 = [1, 2].map { index in
                var unk = Garmin_Unk12()
                unk.unk1 = UInt32(index)
                unk.unk2 = 5
                return unk
            }

            var out = Garmin_Contact()
            out.id = contact.id.uuidString
            out.fullName = contact.name
            out.firstName = contact.name
            out.lastName = ""
            out.phone = [phone]
            out.updateTime = UInt64(now.timeIntervalSince1970 * 1000)
            return out
        }
        return (try? response.serializedData()) ?? Data()
    }
}
