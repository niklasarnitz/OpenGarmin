import Testing
import Foundation
@testable import GarminTransport

// Byte layouts follow Gadgetbridge's CommunicatorV2.processHandleManagement: handle 0, type, client id 2 as
// a little-endian long, then the message fields.

@Test func controlRequestsMatchGadgetbridgeLayout() {
    #expect(MLRControl.closeAllRequest() == Data([0, 5, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    #expect(MLRControl.registerRequest(service: 1, reliable: true) == Data([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2]))
}

@Test func closeHandleReplyNamesServiceAndHandle() {
    // CLOSE_HANDLE_RESP for FILE_TRANSFER_2 (0x2018) on handle 4, status 0.
    #expect(MLRControl.decode(Data([0, 3, 2, 0, 0, 0, 0, 0, 0, 0, 0x18, 0x20, 4, 0])) == .closeHandle(service: 0x2018, handle: 4))
}

@Test func handshakeOpensGFDIOnTheHandleTheWatchAssigns() {
    var handshake = GFDIHandshake()
    // CLOSE_ALL_RESP, then the register request for GFDI goes out.
    let register = handshake.receive(Data([0, 6, 2, 0, 0, 0, 0, 0, 0, 0]))
    #expect(register == Data([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2]))
    #expect(handshake.step == .registeringGFDI)

    // REGISTER_ML_RESP for service 1, status 0, handle 4.
    #expect(handshake.receive(Data([0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 4])) == nil)
    #expect(handshake.step == .open(handle: 4))
}

@Test func handshakeIgnoresRepliesForAnotherClientOrService() {
    var handshake = GFDIHandshake()
    #expect(handshake.receive(Data([0, 6, 9, 0, 0, 0, 0, 0, 0, 0])) == nil)
    #expect(handshake.step == .closingAll)

    _ = handshake.receive(Data([0, 6, 2, 0, 0, 0, 0, 0, 0, 0]))
    #expect(handshake.receive(Data([0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 4])) == nil)
    #expect(handshake.step == .registeringGFDI)
}

@Test func handshakeReportsARefusedRegistration() {
    var handshake = GFDIHandshake()
    _ = handshake.receive(Data([0, 6, 2, 0, 0, 0, 0, 0, 0, 0]))
    _ = handshake.receive(Data([0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0]))
    #expect(handshake.step == .refused(status: 1))
}

@Test func fileTransferRegisterReplyFromAVenu4CarriesTheMLRFlagInItsHandle() {
    // Captured from a Venu 4: FILE_TRANSFER_2 (0x2018) opened with status 0 on handle 0x83, reliable.
    let reply = Data(hex: "00010200000000000000182000830101")!
    #expect(MLRControl.decode(reply) == .register(service: 0x2018, status: 0, handle: 0x83, reliable: true))
    // Its data packets carry only the low three bits: 0xB0 = MLR flag | handle 3 << 4.
    #expect(MLRPacket(decoding: Data([0xB0, 0x40, 0, 0, 0]))?.handle == UInt8(3))
}

@Test func realtimeRegistrationIsUnreliable() {
    // REGISTER_ML for service 16 (accelerometer) with no MLR framing: client id 2, reliable flag 0.
    #expect(Array(MLRControl.registerRequest(service: 16, reliable: false)) == [0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0])
    #expect(Array(MLRControl.registerRequest(service: 16, reliable: true)) == [0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 16, 0, 2])
}
