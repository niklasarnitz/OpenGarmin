import Foundation
import GarminProtobuf

/// A Connect IQ app, watch face, data field or widget the watch lists as installed.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable, CaseIterable {
        case watchApp, watchFace, dataField, widget, audioContentProvider, activity, other
    }

    /// The store app ID, which the watch uses to name the app.
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var version: UInt32?
    /// System apps come with the watch and have no file on it, so the watch does not let them be deleted.
    public var isSystem: Bool

    public init(id: UUID, name: String, kind: Kind, version: UInt32?, isSystem: Bool) {
        self.id = id; self.name = name; self.kind = kind; self.version = version; self.isSystem = isSystem
    }
}

extension InstalledApp {
    /// Reads one entry of the installed-apps list. A system app has no file name, as in Gadgetbridge.
    init?(proto app: GDI_Proto_ConnectIQInstalledApps_GetInstalledAppsResponse.InstalledApp) {
        guard let id = UUID(garminBytes: app.storeAppID) else { return nil }
        self.init(id: id, name: app.name, kind: Kind(proto: app.appType),
                  version: app.hasVersion ? app.version : nil, isSystem: !app.hasFilename)
    }

    var protoAppType: GDI_Proto_ConnectIQInstalledApps_AppType {
        switch kind {
        case .watchApp: .watchApp
        case .watchFace: .watchFace
        case .dataField: .dataField
        case .widget: .widget
        case .audioContentProvider: .audioContentProvider
        case .activity: .activity
        case .other: .unknownAppType
        }
    }
}

extension InstalledApp.Kind {
    init(proto type: GDI_Proto_ConnectIQInstalledApps_AppType) {
        self = switch type {
        case .watchApp: .watchApp
        case .watchFace: .watchFace
        case .dataField: .dataField
        case .widget: .widget
        case .audioContentProvider: .audioContentProvider
        case .activity: .activity
        default: .other
        }
    }
}

extension UUID {
    /// The 16 bytes of a UUID in the order the watch sends them: the same bytes Gadgetbridge's `UuidUtil` reads.
    init?(garminBytes data: Data) {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                         b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    var garminBytes: Data {
        var uuid = self.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}
