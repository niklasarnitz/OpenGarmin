import Testing
import Foundation
import GarminModels
@testable import GarminProtocol

@Test func createFilePayloadLayout() {
    let message = GFDICreateFile(fileSize: 0x0102_0304, dataType: 5, subType: 6, path: "", fileID: 0x0807_0605_0403_0201)
    #expect(Array(message.frame().payload) == [
        0x04, 0x03, 0x02, 0x01,  // fileSize
        0x05, 0x06,              // dataType, subType
        0x00, 0x00,              // fileIndex
        0x00,                    // reserved
        0x00,                    // subTypeMask
        0xFF, 0xFF,              // numberMask
        0x00, 0x00,              // path length (u16)
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // fileID
    ])
}

@Test func downloadRequestPayloadLayout() {
    let message = GFDIDownloadRequest(fileIndex: 0x0102, dataOffset: 0x0304_0506, mode: .new,
                                      crcSeed: 0x0A0B, dataSize: 0x1122_3344, flags: 1)
    #expect(Array(message.frame().payload) == [
        0x02, 0x01, 0x06, 0x05, 0x04, 0x03, 0x01, 0x0B, 0x0A, 0x44, 0x33, 0x22, 0x11, 0x01,
    ])
}

@Test func notificationUpdatePayloadLayout() {
    let message = GFDINotificationUpdate(kind: .add, flags: [.foreground], category: .sms, count: 3,
                                         notificationID: 0x1122_3344, phoneFlags: [.newActions, .hasAttachments])
    #expect(message.frame().messageType == 5033)
    #expect(Array(message.frame().payload) == [0x00, 0x02, 0x0C, 0x03, 0x44, 0x33, 0x22, 0x11, 0x06])
}

@Test func musicEntityUpdateWritesEntriesInAttributeOrder() {
    let message = GFDIMusicEntityUpdate(attributes: [.trackTitle: "Ab", .playerVolume: ""])
    #expect(Array(message.frame().payload) == [
        0x03, 0x00, 0x02, 0x00,              // player volume: empty value
        0x05, 0x02, 0x02, 0x00, 0x41, 0x62,  // track title "Ab"
    ])
}

@Test func setFileFlagsUsesGadgetbridgeBits() {
    let message = GFDISetFileFlags(fileIndex: 0x0102, flags: [.crypto, .read])
    #expect(Array(message.frame().payload) == [0x02, 0x01, 0x84])
}

@Test func systemEventCarriesStrings() {
    let message = GFDISystemEvent(.deviceDisconnect, value: .text("hi"))
    #expect(Array(message.frame().payload) == [11, 2, 0x68, 0x69])
}

@Test func setDeviceSettingsWritesValuesInOrder() {
    let message = GFDISetDeviceSettings(settings: [
        .weatherAlertsEnabled: .bool(false),
        .timeZoneOffset: .int(-3600),
        .deviceName: .text("Watch"),
    ])
    #expect(Array(message.frame().payload) == [
        3,
        0, 5, 0x57, 0x61, 0x74, 0x63, 0x68,      // device name, length-prefixed
        3, 4, 0xF0, 0xF1, 0xFF, 0xFF,            // time zone offset -3600 as i32 LE
        8, 1, 0,                                 // weather alerts disabled
    ])
}
