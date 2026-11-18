import Foundation
import GarminFIT
import GarminModels
import GarminProtobuf

// Installs and removes on the watch, as Gadgetbridge's GarminPrgInstallHandler, GarminGpxRouteInstallHandler and
// GarminSupport do: a Connect IQ .prg goes up as data type 255 sub type 17, a GPX route as a FIT course (type 128,
// sub type 6), and the installed apps come from the Connect IQ installed-apps service.

extension GFDISession {
    /// Connect IQ apps are data type 255, sub type 17 (Gadgetbridge's `FileType.PRG`).
    private static let prgDataType: UInt8 = 255
    private static let prgSubType: UInt8 = 17
    /// FIT courses are sub type 6.
    private static let courseSubType: UInt8 = 6

    /// Uploads a Connect IQ app, then asks for the installed apps again so the new one is listed.
    func installApp(_ prg: Data, onProgress: (@MainActor (Double) -> Void)?) async throws {
        _ = try ConnectIQPrg(data: prg)
        try await transferFile(prg, subType: Self.prgSubType, dataType: Self.prgDataType, onProgress: onProgress)
        try await requestInstalledApps()
    }

    /// Converts a GPX track to a FIT course, as Gadgetbridge does, and uploads it.
    func installCourse(gpx: Data, name: String, includeTurns: Bool,
                       onProgress: (@MainActor (Double) -> Void)?) async throws {
        let points = try GPXTrack.points(in: gpx)
        let course = CourseFitEncoder.encode(points, name: name, start: .now, includeTurns: includeTurns)
        try await transferFile(course, subType: Self.courseSubType, onProgress: onProgress)
    }

    /// Asks the watch for every installed app. The answer comes back as `.installedApps`.
    func requestInstalledApps() async throws {
        var request = GDI_Proto_ConnectIQInstalledApps_GetInstalledAppsRequest()
        request.appType = .all
        var service = GDI_Proto_ConnectIQInstalledApps_ConnectIQInstalledAppsService()
        service.getInstalledAppsRequest = request
        var smart = GarminVivomovehr_Smart()
        smart.connectIqInstalledAppsService = service
        try await sendProtobufRequest(smart)
    }

    /// Deletes an app the watch installed from a file. System apps have no file, so they cannot be deleted.
    func deleteInstalledApp(_ app: InstalledApp) async throws {
        guard !app.isSystem else { throw GarminWatchError.unsupported("\(app.name) came with the watch and cannot be deleted.") }
        var request = GDI_Proto_ConnectIQInstalledApps_DeleteAppRequest()
        request.storeAppID = app.id.garminBytes
        request.appType = app.protoAppType
        var service = GDI_Proto_ConnectIQInstalledApps_ConnectIQInstalledAppsService()
        service.deleteAppRequest = request
        var smart = GarminVivomovehr_Smart()
        smart.connectIqInstalledAppsService = service
        try await sendProtobufRequest(smart)
    }

    /// Handles the watch's installed-apps replies. The list is reported; a successful delete asks for the list again.
    func receiveInstalledApps(_ service: GDI_Proto_ConnectIQInstalledApps_ConnectIQInstalledAppsService) {
        if service.hasGetInstalledAppsResponse {
            let apps = service.getInstalledAppsResponse.installedApp.compactMap(InstalledApp.init(proto:))
            output(.installedApps(apps))
        } else if service.hasDeleteAppResponse, service.deleteAppResponse.status == .ok {
            Task { try? await self.requestInstalledApps() }
        }
    }
}
