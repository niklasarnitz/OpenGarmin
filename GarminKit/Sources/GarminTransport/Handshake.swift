import Foundation

/// Control-channel messages on handle 0, laid out as Gadgetbridge's CommunicatorV2.processHandleManagement reads them.
/// Every message carries Gadgetbridge's client id (2, little-endian) in bytes 2...9.
enum MLRControl {
    static let gfdiService: UInt16 = 1

    private static let clientID: [UInt8] = [2, 0, 0, 0, 0, 0, 0, 0]
    private static let closeAllType: UInt8 = 5
    private static let closeAllResponseType: UInt8 = 6
    private static let registerRequestType: UInt8 = 0
    private static let registerResponseType: UInt8 = 1
    private static let closeHandleResponseType: UInt8 = 3

    enum Reply: Equatable {
        case closeAll
        case register(service: UInt16, status: UInt8, handle: UInt8)
        /// The watch closed a service: it has sent everything on it.
        case closeHandle(service: UInt16, handle: UInt8)
    }

    /// Drops every handle a previous client (for example a phone) left on the watch.
    static func closeAllRequest() -> Data {
        Data([0, closeAllType] + clientID + [0, 0, 0])
    }

    static func registerRequest(service: UInt16, reliable: Bool) -> Data {
        Data([0, registerRequestType] + clientID + [UInt8(service & 0xFF), UInt8(service >> 8), reliable ? 2 : 0])
    }

    /// Nil for anything that is not a recognised control reply for this client. Gadgetbridge ignores replies
    /// whose client id is not its own, so this does too.
    static func decode(_ data: Data) -> Reply? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, bytes[0] == 0, Array(bytes[2..<10]) == clientID else { return nil }
        switch bytes[1] {
        case closeAllResponseType:
            return .closeAll
        case registerResponseType:
            guard bytes.count >= 14 else { return nil }
            return .register(service: UInt16(bytes[10]) | UInt16(bytes[11]) << 8, status: bytes[12], handle: bytes[13])
        case closeHandleResponseType:
            guard bytes.count >= 13 else { return nil }
            return .closeHandle(service: UInt16(bytes[10]) | UInt16(bytes[11]) << 8, handle: bytes[12])
        default:
            return nil
        }
    }
}

/// Opens the GFDI service: CLOSE_ALL, then REGISTER_ML for GFDI with reliable (MLR) framing.
struct GFDIHandshake: Equatable {
    enum Step: Equatable {
        case closingAll
        case registeringGFDI
        /// GFDI is open on this handle. The MLR packets carry only the low three bits of it.
        case open(handle: UInt8)
        case refused(status: UInt8)
    }

    private(set) var step: Step = .closingAll

    /// Consumes one control-channel packet and returns the request to send next, if any.
    mutating func receive(_ data: Data) -> Data? {
        guard let reply = MLRControl.decode(data) else { return nil }
        switch (step, reply) {
        case (.closingAll, .closeAll):
            step = .registeringGFDI
            return MLRControl.registerRequest(service: MLRControl.gfdiService, reliable: true)
        case let (.registeringGFDI, .register(service, status, handle)) where service == MLRControl.gfdiService:
            step = status == 0 ? .open(handle: handle & 0x07) : .refused(status: status)
        default:
            break
        }
        return nil
    }
}
