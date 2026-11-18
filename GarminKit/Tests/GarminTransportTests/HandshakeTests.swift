import Testing
import Foundation
@testable import GarminTransport

// Byte layouts follow Gadgetbridge's CommunicatorV2.processHandleManagement: handle 0, type, client id 2 as
// a little-endian long, then the message fields.

@Test func controlRequestsMatchGadgetbridgeLayout() {
    #expect(MLRControl.closeAllRequest() == Data([0, 5, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    #expect(MLRControl.registerRequest(service: 1, reliable: true) == Data([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2]))
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
