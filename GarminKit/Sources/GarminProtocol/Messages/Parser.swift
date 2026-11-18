import Foundation
import GarminCore

/// Decodes a frame into its typed message.
///
/// A frame with an unknown type, or a type this module does not model, comes back as `GFDIUnhandled`.
/// So does a frame whose payload fails to decode. A RESPONSE that fails to decode comes back as the raw
/// `GFDIResponse`, so its status is kept.
public enum GFDIMessageParser {
    public static func parse(_ frame: GFDIFrame) -> any GFDIIncoming {
        guard let id = frame.id else { return unhandled(frame) }
        do {
            switch id {
            case .response:
                let response = try GFDIResponse(frame: frame)
                if let typed = try? typedStatus(response) { return typed }
                return response
            case .deviceInformation: return try GFDIDeviceInformation(frame: frame)
            case .configuration: return try GFDIConfiguration(frame: frame)
            case .currentTimeRequest: return try GFDICurrentTimeRequest(frame: frame)
            case .synchronization: return try GFDISynchronization(frame: frame)
            case .batteryStatus: return try GFDIBatteryStatus(frame: frame)
            case .fileAvailable: return try GFDIFileAvailable(frame: frame)
            case .fileTransferData: return try GFDIFileTransferData(frame: frame)
            case .createFile: return try GFDICreateFile(frame: frame)
            case .fitDefinition: return try GFDIFitDefinition(frame: frame)
            case .fitData: return try GFDIFitData(frame: frame)
            case .weatherRequest: return try GFDIWeatherRequest(frame: frame)
            case .notificationControl: return try GFDINotificationControl(frame: frame)
            case .notificationSubscription: return try GFDINotificationSubscription(frame: frame)
            case .findMyPhoneRequest: return try GFDIFindMyPhoneRequest(frame: frame)
            case .findMyPhoneCancel: return try GFDIFindMyPhoneCancel(frame: frame)
            case .musicControl: return try GFDIMusicControl(frame: frame)
            case .musicControlCapabilities: return try GFDIMusicControlCapabilities(frame: frame)
            case .protobufRequest: return try GFDIProtobufRequest(frame: frame)
            case .protobufResponse: return try GFDIProtobufResponse(frame: frame)
            case .authNegotiation: return try GFDIAuthNegotiation(frame: frame)
            default: return unhandled(frame)
            }
        } catch {
            return unhandled(frame)
        }
    }

    /// The typed body of a RESPONSE, or nil when this module has no status type for the answered message.
    private static func typedStatus(_ response: GFDIResponse) throws -> (any GFDIIncoming)? {
        guard let original = GFDIMessageID(rawValue: response.originalType) else { return nil }
        var body = ByteReader(response.body)
        switch original {
        case .downloadRequest: return try GFDIDownloadRequestStatus(status: response.status, body: &body)
        case .uploadRequest: return try GFDIUploadRequestStatus(status: response.status, body: &body)
        case .fileTransferData: return try GFDIFileTransferDataStatus(status: response.status, body: &body)
        case .createFile: return try GFDICreateFileStatus(status: response.status, body: &body)
        case .filter: return try GFDIFilterStatus(status: response.status, body: &body)
        case .setFileFlag: return try GFDISetFileFlagsStatus(status: response.status, body: &body)
        case .supportedFileTypesRequest: return try GFDISupportedFileTypesStatus(status: response.status, body: &body)
        case .fitDefinition: return try GFDIFitDefinitionStatus(status: response.status, body: &body)
        case .fitData: return try GFDIFitDataStatus(status: response.status, body: &body)
        case .notificationControl: return try GFDINotificationControlStatus(status: response.status, body: &body)
        case .notificationData: return try GFDINotificationDataStatus(status: response.status, body: &body)
        case .notificationSubscription: return try GFDINotificationSubscriptionStatus(status: response.status, body: &body)
        case .authNegotiation: return try GFDIAuthNegotiationStatus(status: response.status, body: &body)
        case .protobufRequest, .protobufResponse: return try GFDIProtobufStatus(response: response)
        default: return nil
        }
    }

    private static func unhandled(_ frame: GFDIFrame) -> GFDIUnhandled {
        GFDIUnhandled(messageType: frame.messageType, payload: frame.payload)
    }
}
