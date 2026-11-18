import Foundation
import Testing
import GarminCore
import GarminModels
import GarminProtobuf
import GarminProtocol
import GarminTransport
@testable import GarminSession

private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

private func section(_ magic: UInt32, _ content: Data) -> Data { be32(magic) + be32(UInt32(content.count)) + content }

/// A Connect IQ .prg with one entry point of the given app type, laid out as Gadgetbridge's garmin_prg.ksy reads it.
private func prgFile(appType: UInt32, uuid: UUID) -> Data {
    let entry = uuid.garminBytes + be32(0) + be32(0) + be32(0) + be32(0) + be32(appType)
    return section(0xd000_d000, Data(count: 4)) + section(0x6060_c0de, Data([0x00, 0x01]) + entry) + be32(0)
}

private let moon = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!

@Test func prgReadsTheEntryPointIDAndAppType() throws {
    let file = prgFile(appType: 1, uuid: moon) + Data(repeating: 0x5A, count: 500)
    let prg = try ConnectIQPrg(data: file)

    #expect(prg.appID == moon)
    #expect(prg.type == .watchApp)
    #expect(prg.size == file.count)
}

@Test func prgTypesFollowTheEntryPointAppType() throws {
    // Gadgetbridge's app types: 0 watch face, 2 data field, 3 widget, 6 glance.
    #expect(try ConnectIQPrg(data: prgFile(appType: 0, uuid: moon)).type == .watchFace)
    #expect(try ConnectIQPrg(data: prgFile(appType: 2, uuid: moon)).type == .dataField)
    #expect(try ConnectIQPrg(data: prgFile(appType: 3, uuid: moon)).type == .widget)
    #expect(try ConnectIQPrg(data: prgFile(appType: 6, uuid: moon)).type == .glance)
}

@Test func prgRejectsOtherFilesTruncatedFilesAndFilesWithoutAnEntryPoint() throws {
    #expect(throws: ConnectIQPrgError.notPRG) { try ConnectIQPrg(data: Data("hello".utf8)) }
    // Dropping the end marker and the last four bytes of the entry points cuts the section short.
    #expect(throws: ConnectIQPrgError.truncated) { try ConnectIQPrg(data: prgFile(appType: 1, uuid: moon).dropLast(8)) }
    let noEntryPoints = section(0xd000_d000, Data(count: 4)) + be32(0)
    #expect(throws: ConnectIQPrgError.noEntryPoint) { try ConnectIQPrg(data: noEntryPoints) }
}

@Test func installedAppsReplyMapsSystemAndUserApps() throws {
    var user = GDI_Proto_ConnectIQInstalledApps_GetInstalledAppsResponse.InstalledApp()
    user.storeAppID = moon.garminBytes
    user.appType = .watchFace
    user.name = "Moon Phase"
    user.version = 3
    user.filename = "moon.prg"
    user.disabled = false
    var system = GDI_Proto_ConnectIQInstalledApps_GetInstalledAppsResponse.InstalledApp()
    system.storeAppID = Data(repeating: 0x11, count: 16)
    system.appType = .dataField
    system.name = "Gradient Sky"
    system.disabled = false
    // An entry whose ID is not 16 bytes cannot be named, so it is left out.
    var broken = GDI_Proto_ConnectIQInstalledApps_GetInstalledAppsResponse.InstalledApp()
    broken.storeAppID = Data([1, 2, 3])
    broken.appType = .watchFace
    broken.name = "Broken"
    broken.disabled = false

    var response = GDI_Proto_ConnectIQInstalledApps_GetInstalledAppsResponse()
    response.availableSpace = 1 << 20
    response.availableSlots = 8
    response.installedApp = [user, system, broken]
    var service = GDI_Proto_ConnectIQInstalledApps_ConnectIQInstalledAppsService()
    service.getInstalledAppsResponse = response
    var smart = GarminVivomovehr_Smart()
    smart.connectIqInstalledAppsService = service

    // Through the wire, as the watch sends it.
    let received = try GarminVivomovehr_Smart(serializedBytes: smart.serializedData())
    let apps = received.connectIqInstalledAppsService.getInstalledAppsResponse.installedApp
        .compactMap(InstalledApp.init(proto:))

    #expect(apps == [
        InstalledApp(id: moon, name: "Moon Phase", kind: .watchFace, version: 3, isSystem: false),
        InstalledApp(id: UUID(garminBytes: Data(repeating: 0x11, count: 16))!, name: "Gradient Sky",
                     kind: .dataField, version: nil, isSystem: true),
    ])
}

/// A watch that accepts a file upload: the create, the upload request and every chunk are acknowledged.
@MainActor
private func acceptsInstall(_ frame: GFDIFrame) -> [GFDIFrame] {
    switch frame.messageType {
    case GFDIMessageID.createFile.rawValue:
        return [GFDICreateFileStatus(result: .ok, fileIndex: 3, dataType: 255, subType: 17, fileNumber: 9).frame()]
    case GFDIMessageID.uploadRequest.rawValue:
        return [GFDIUploadRequestStatus(result: .ok, dataOffset: 0, maxFileSize: 1 << 20, crcSeed: 0).frame()]
    case GFDIMessageID.fileTransferData.rawValue:
        guard let chunk = try? GFDIFileTransferData(frame: frame) else { return [] }
        return [GFDIFileTransferDataStatus(transfer: .ok, dataOffset: chunk.dataOffset + UInt32(chunk.data.count)).frame()]
    default:
        return []
    }
}

/// The protobuf message in a PROTOBUF_REQUEST frame the phone sent, which fits in one chunk here.
private func sentSmart(_ frame: GFDIFrame) throws -> GarminVivomovehr_Smart {
    var reassembler = GFDIProtobufReassembler()
    let request = try GFDIProtobufRequest(frame: frame)
    let bytes = try #require(try reassembler.accept(request.chunk))
    return try GarminVivomovehr_Smart(serializedBytes: bytes)
}

@MainActor
@Test func installingAPRGUploadsItAsAConnectIQAppThenAsksForTheAppList() async throws {
    let store = try makeStore()
    let link = FakeLink()
    link.reply = acceptsInstall
    let session = GFDISession(link: link, importer: makeImporter(store), capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { _ in }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    // Bigger than one packet, so the upload takes several chunks.
    let file = prgFile(appType: 1, uuid: moon) + Data(repeating: 0x5A, count: 1000)
    var fractions: [Double] = []
    try await session.installApp(file, onProgress: { fractions.append($0) })

    // CREATE_FILE: data type 255, sub type 17 (Connect IQ app), with the file size.
    let createFile = try GFDICreateFile(frame: link.framesSent(of: .createFile)[0])
    #expect(createFile.dataType == 255)
    #expect(createFile.subType == 17)
    #expect(createFile.fileSize == UInt32(file.count))

    var uploaded = Data()
    for frame in link.framesSent(of: .fileTransferData) {
        let chunk = try GFDIFileTransferData(frame: frame)
        if Int(chunk.dataOffset) == uploaded.count { uploaded.append(chunk.data) }
    }
    #expect(uploaded == file)
    #expect(link.framesSent(of: .fileTransferData).count > 1)
    #expect(fractions.first == 0)
    #expect(fractions.last == 1)

    // The upload ends with a sync-complete event, then the phone asks for every installed app.
    let request = try sentSmart(link.framesSent(of: .protobufRequest).last!)
    #expect(request.connectIqInstalledAppsService.getInstalledAppsRequest.appType == .all)
}

@MainActor
@Test func deletingAnAppSendsItsIDAndTypeAndRefusesSystemApps() async throws {
    let store = try makeStore()
    let link = FakeLink()
    let session = GFDISession(link: link, importer: makeImporter(store), capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { _ in }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    let app = InstalledApp(id: moon, name: "Moon Phase", kind: .watchFace, version: 3, isSystem: false)
    try await session.deleteInstalledApp(app)

    let request = try sentSmart(link.framesSent(of: .protobufRequest).last!)
    #expect(request.connectIqInstalledAppsService.deleteAppRequest.storeAppID == moon.garminBytes)
    #expect(request.connectIqInstalledAppsService.deleteAppRequest.appType == .watchFace)

    let system = InstalledApp(id: moon, name: "Gradient Sky", kind: .watchFace, version: nil, isSystem: true)
    await #expect(throws: GarminWatchError.self) { try await session.deleteInstalledApp(system) }
}

@MainActor
@Test func installedAppsReplyIsReportedToTheService() async throws {
    let store = try makeStore()
    let link = FakeLink()
    var listed: [InstalledApp]?
    let session = GFDISession(link: link, importer: makeImporter(store), capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { output in
        if case let .installedApps(apps) = output { listed = apps }
    }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    var app = GDI_Proto_ConnectIQInstalledApps_GetInstalledAppsResponse.InstalledApp()
    app.storeAppID = moon.garminBytes
    app.appType = .watchFace
    app.name = "Moon Phase"
    app.filename = "moon.prg"
    app.disabled = false
    var response = GDI_Proto_ConnectIQInstalledApps_GetInstalledAppsResponse()
    response.availableSpace = 1 << 20
    response.availableSlots = 8
    response.installedApp = [app]
    var service = GDI_Proto_ConnectIQInstalledApps_ConnectIQInstalledAppsService()
    service.getInstalledAppsResponse = response
    var smart = GarminVivomovehr_Smart()
    smart.connectIqInstalledAppsService = service
    let bytes = try smart.serializedData()
    link.watchSends(GFDIProtobufResponse(chunk: GFDIProtobufChunk(requestID: 1, dataOffset: 0,
                                                                  totalLength: UInt32(bytes.count),
                                                                  data: bytes)).frame())

    try await waitUntil { listed != nil }
    #expect(listed == [InstalledApp(id: moon, name: "Moon Phase", kind: .watchFace, version: nil, isSystem: false)])
}
