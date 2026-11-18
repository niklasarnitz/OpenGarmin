import Foundation
import Testing
import GarminCore
import GarminFIT
import GarminModels
import GarminProtobuf
import GarminProtocol
import GarminTransport
@testable import GarminSession

/// A file transfer service on the fake link. It records the phone's request, then sends the scripted payloads and closes.
@MainActor
final class FakeTransferChannel: GarminServiceChannel {
    nonisolated let incoming: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private let payloads: [Data]
    private(set) var requests: [Data] = []

    init(payloads: [Data]) {
        self.payloads = payloads
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        incoming = stream
        sink = continuation
    }

    func send(_ payload: Data) async throws {
        requests.append(payload)
        for part in payloads { sink.yield(part) }
        sink.finish()
    }
}

/// A link that records what the phone writes and answers it with the frames a scripted watch returns.
@MainActor
final class FakeLink: GarminServiceLink {
    nonisolated let states: AsyncStream<LinkState>
    nonisolated let incomingFrames: AsyncStream<Data>
    private let stateSink: AsyncStream<LinkState>.Continuation
    private let frameSink: AsyncStream<Data>.Continuation

    /// Every frame the phone wrote, decoded.
    private(set) var sent: [GFDIFrame] = []
    /// The scripted watch: the frames it sends back for each frame the phone writes.
    var reply: (@MainActor (GFDIFrame) -> [GFDIFrame])?
    /// What the watch sends on each file transfer service the phone opens.
    var transferPayloads: [Data] = []
    private(set) var transfers: [FakeTransferChannel] = []

    init() {
        let (stateStream, stateContinuation) = AsyncStream.makeStream(of: LinkState.self)
        let (frameStream, frameContinuation) = AsyncStream.makeStream(of: Data.self)
        states = stateStream
        stateSink = stateContinuation
        incomingFrames = frameStream
        frameSink = frameContinuation
    }

    func connect() async throws {
        stateSink.yield(.connecting)
        stateSink.yield(.ready(protocolVersion: 2, maxWritePayload: 100))
    }

    func disconnect() async {
        stateSink.yield(.disconnected)
    }

    func send(_ gfdiFrame: Data) async throws {
        let frame = try GFDIFrame.decode(gfdiFrame)
        sent.append(frame)
        for response in reply?(frame) ?? [] {
            frameSink.yield(response.encoded())
        }
    }

    /// The watch sends a frame to the phone. Frames sent before the phone reads them wait in the stream.
    func watchSends(_ frame: GFDIFrame) {
        frameSink.yield(frame.encoded())
    }

    func framesSent(of id: GFDIMessageID) -> [GFDIFrame] {
        sent.filter { $0.messageType == id.rawValue }
    }

    func openFileTransfer() async throws -> any GarminServiceChannel {
        let channel = FakeTransferChannel(payloads: transferPayloads)
        transfers.append(channel)
        return channel
    }
}

@MainActor
func makeStore() throws -> SessionStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    return try SessionStore(directory: directory, defaults: defaults)
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within 5 seconds")
}

/// DEVICE_INFORMATION as a Venu-style watch sends it: protocol 2.00, no Bluetooth MAC.
func deviceInformationFrame() -> GFDIFrame {
    var w = ByteWriter()
    w.writeUInt16(200)
    w.writeUInt16(3111)
    w.writeUInt32(1234)
    w.writeUInt16(1842)
    w.writeUInt16(255)
    w.writeString("Venu 4")
    w.writeString("Venu 4")
    w.writeString("Venu 4")
    return GFDIFrame(messageType: GFDIMessageID.deviceInformation.rawValue, payload: w.data)
}

private func fileIndex(_ frame: GFDIFrame) -> UInt16 {
    UInt16(frame.payload[0]) | UInt16(frame.payload[1]) << 8
}

private func directoryEntry(index: UInt16, dataType: UInt8, subType: UInt8, size: Int, timestamp: UInt32) -> Data {
    var w = ByteWriter()
    w.writeUInt16(index)
    w.writeUInt8(dataType)
    w.writeUInt8(subType)
    w.writeUInt16(0) // file number
    w.writeUInt8(0) // specific flags
    w.writeUInt8(0) // file flags
    w.writeUInt32(UInt32(size))
    w.writeUInt32(timestamp)
    return w.data
}

/// Two monitoring records 60 s apart with a 50-step increase: one FIT file, one step interval.
/// The records are recent, because the store drops samples older than its retention period.
private func activityFIT(ageSeconds: Int64) -> Data {
    let start = Int64(GarminTime.garminSeconds(from: .now)) - ageSeconds
    return FitEncoder.encodeFile([
        FitEncodeMessage(globalNumber: 55, fields: [
            FitEncodeField(253, .uint32, .int(start)), FitEncodeField(5, .enumeration, .int(1)),
            FitEncodeField(3, .uint32, .int(100)),
        ]),
        FitEncodeMessage(globalNumber: 55, fields: [
            FitEncodeField(253, .uint32, .int(start + 60)), FitEncodeField(5, .enumeration, .int(1)),
            FitEncodeField(3, .uint32, .int(150)),
        ]),
    ])
}

/// The phone's ACK to DEVICE_INFORMATION, byte for byte: RESPONSE (5000) for 5024, status 0, then
/// protocol 150, unknown product and unit, software 77.91, the phone's name, manufacturer and model, flag 0.
private let deviceInformationAck: [UInt8] = [
    0xA0, 0x13, 0x00,
    0x96, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0x6F, 0x1E, 0xFF, 0xFF,
    0x06, 0x69, 0x50, 0x68, 0x6F, 0x6E, 0x65,
    0x05, 0x41, 0x70, 0x70, 0x6C, 0x65,
    0x06, 0x69, 0x50, 0x68, 0x6F, 0x6E, 0x65,
    0x00,
]

@MainActor
@Test func connectHandshakeAnswersWatchAndAdvertisesCapabilities() async throws {
    let store = try makeStore()
    store.pairedWatch = PairedWatch(id: UUID(), name: "Venu 4", catalogID: "garmin_venu_4")
    let link = FakeLink()
    link.watchSends(deviceInformationFrame())
    link.watchSends(GFDIConfiguration(capabilities: [.sync, .gncs, .findMyWatch]).frame())

    let service = GarminWatchService(store: store, makeLink: { _ in link })
    // The phone starts a directory sync right after the handshake, so wait for that request.
    try await waitUntil { link.sent.count >= 12 }

    let sent = link.sent
    #expect(sent.count >= 12)
    #expect(service.state != .connecting)
    #expect(Array(sent[0].payload) == deviceInformationAck)
    // CONFIGURATION ACK: RESPONSE (5000) for 5050, status 0, no body.
    #expect(sent[1].messageType == GFDIMessageID.response.rawValue)
    #expect(Array(sent[1].payload) == [0xBA, 0x13, 0x00])
    // The phone's own capabilities follow as a CONFIGURATION frame.
    let phoneCapabilities = try GFDIConfiguration(frame: sent[2]).capabilities
    #expect(phoneCapabilities.contains(.sync))
    #expect(phoneCapabilities.contains(.findMyPhone))
    #expect(!phoneCapabilities.contains(.livetrack))
    // Then supported file types, device settings, time, sync ready, battery and the pairing and sync events.
    #expect(sent[3...10].map(\.messageType) == [5031, 5026, 5030, 5030, 5043, 5030, 5030, 5030])
}

/// The import stage over a store's directory. The events it reports are collected on the main actor for the test.
@MainActor
final class ImportLog {
    private(set) var events: [FITImporter.Event] = []
    let importer: FITImporter

    init(store: SessionStore, beforeImport: @escaping @Sendable () async -> Void = {}) {
        let (stream, sink) = AsyncStream.makeStream(of: FITImporter.Event.self)
        importer = FITImporter(history: HistoryStore(directory: store.directory), report: { sink.yield($0) },
                               beforeImport: beforeImport)
        Task { for await event in stream { self.events.append(event) } }
    }

    var imported: [HealthBatch] {
        events.compactMap { event in
            if case let .imported(batch, _) = event { return batch }
            return nil
        }
    }

    /// The retained history after the last import.
    var history: HealthBatch {
        var latest = HealthBatch()
        for case let .imported(_, history) in events { latest = history }
        return latest
    }

    var finishes: Int {
        events.filter { if case .finished = $0 { true } else { false } }.count
    }
}

/// An import stage over a store's directory that reports nothing.
@MainActor
func makeImporter(_ store: SessionStore) -> FITImporter {
    FITImporter(history: HistoryStore(directory: store.directory), report: { _ in })
}

/// The files waiting in the store's inbox.
@MainActor
func inboxCount(_ store: SessionStore) -> Int {
    HistoryStore(directory: store.directory).pendingFiles().count
}

/// Answers each download request with the file at its index, as the watch does.
@MainActor
private func serveDownloads(_ files: [UInt16: Data]) -> @MainActor (GFDIFrame) -> [GFDIFrame] {
    { frame in
        guard frame.messageType == GFDIMessageID.downloadRequest.rawValue else { return [] }
        let data = files[fileIndex(frame)] ?? Data()
        return [
            GFDIDownloadRequestStatus(result: .ok, maxFileSize: UInt32(data.count)).frame(),
            GFDIFileTransferData(crc: 0, dataOffset: 0, data: data).frame(),
        ]
    }
}

@MainActor
@Test func directorySyncDownloadsNewFITFilesAndArchivesThem() async throws {
    let store = try makeStore()
    let link = FakeLink()
    let fit = activityFIT(ageSeconds: 3600)
    let listing = directoryEntry(index: 7, dataType: 128, subType: 4, size: fit.count, timestamp: 1000)
        + directoryEntry(index: 9, dataType: 255, subType: 245, size: 10, timestamp: 1000) // not a FIT file
    link.reply = serveDownloads([0: listing, 7: fit])

    var outputs: [GFDISessionOutput] = []
    let log = ImportLog(store: store)
    let session = GFDISession(link: link, importer: log.importer, capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { outputs.append($0) }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    await session.requestSync()
    try await waitUntil { outputs.syncFinishes == 1 && log.finishes == 1 }

    #expect(log.imported.map { $0.steps.map(\.value) } == [[50]])
    #expect(log.history.steps.map(\.value) == [50])
    // The listing is requested, then only the FIT file, never the non-FIT entry.
    #expect(link.framesSent(of: .downloadRequest).map(fileIndex) == [0, 7])
    // The FIT file is archived on the watch: file index 7, flags ARCHIVE (0x10).
    #expect(link.framesSent(of: .setFileFlag).map { Array($0.payload) } == [[7, 0, 0x10]])

    // A second sync lists the same file, which is already imported, so it is archived without a download.
    await session.requestSync()
    try await waitUntil { outputs.syncFinishes == 2 }
    #expect(link.framesSent(of: .downloadRequest).map(fileIndex) == [0, 7, 0])
    #expect(log.imported.count == 1)
}

@MainActor
@Test func downloadsContinueWhileTheImportStageIsHeld() async throws {
    let store = try makeStore()
    let link = FakeLink()
    let first = activityFIT(ageSeconds: 3600)
    let second = activityFIT(ageSeconds: 7200)
    let listing = directoryEntry(index: 7, dataType: 128, subType: 4, size: first.count, timestamp: 1000)
        + directoryEntry(index: 8, dataType: 128, subType: 4, size: second.count, timestamp: 2000)
    let serve = serveDownloads([0: listing, 7: first, 8: second])
    var inboxAtArchive: [Int] = []
    link.reply = { frame in
        guard frame.messageType == GFDIMessageID.setFileFlag.rawValue else { return serve(frame) }
        inboxAtArchive.append(inboxCount(store))
        return []
    }

    // The import stage waits at the gate until the test opens it, so the watch's sync runs ahead of it.
    let (gateStream, gate) = AsyncStream.makeStream(of: Void.self)
    let log = ImportLog(store: store, beforeImport: { for await _ in gateStream { break } })
    var outputs: [GFDISessionOutput] = []
    let session = GFDISession(link: link, importer: log.importer, capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { outputs.append($0) }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    await session.requestSync()
    try await waitUntil { outputs.syncFinishes == 1 }
    // Both files were downloaded and archived while the import had not run.
    #expect(log.imported.isEmpty)
    #expect(link.framesSent(of: .setFileFlag).count == 2)
    // Each file was already in the inbox when the watch released it.
    #expect(inboxAtArchive == [1, 2])

    gate.yield(())
    try await waitUntil { log.finishes == 1 }
    // The held files are imported as one batch, and they leave the inbox.
    #expect(log.imported.count == 1)
    #expect(log.history.steps.count == 2)
    #expect(inboxCount(store) == 0)
}

@MainActor
@Test func pendingFilesImportAsOneBatchWithOneWriteAndOneEvent() async throws {
    let store = try makeStore()
    let inbox = HistoryStore(directory: store.directory)
    for (index, age) in [Int64(3600), 7200, 10800].enumerated() {
        try inbox.writeToInbox(activityFIT(ageSeconds: age), fileKey: "0-\(index)-1000-\(index)")
    }

    let log = ImportLog(store: store)
    await log.importer.start()
    try await waitUntil { log.finishes == 1 }

    #expect(log.imported.count == 1)
    #expect(log.history.steps.count == 3)
    let writes = await log.importer.snapshotWrites
    #expect(writes == 1)
    #expect(inboxCount(store) == 0)
}

@MainActor
@Test func inboxFilesLeftByAStoppedAppAreImportedOnRestart() async throws {
    let store = try makeStore()
    // The app stopped after the downloads and before the import ran, so the files are still in the inbox.
    let inbox = HistoryStore(directory: store.directory)
    try inbox.writeToInbox(activityFIT(ageSeconds: 3600), fileKey: "0-7-1000-100")
    try inbox.writeToInbox(Data([1, 2, 3]), fileKey: "0-8-2000-3") // does not decode

    let log = ImportLog(store: store)
    await log.importer.start()
    try await waitUntil { log.finishes == 1 }

    #expect(log.imported.map { $0.steps.map(\.value) } == [[50]])
    #expect(inboxCount(store) == 0)
    // The file that does not decode is recorded as imported, so it is not taken again.
    let known = await log.importer.isKnown("0-8-2000-3")
    #expect(known)
}

@MainActor
@Test func workoutUploadStreamsTheFITFileInChunks() async throws {
    let store = try makeStore()
    let link = FakeLink()
    let plan = WorkoutPlan(name: "Intervals", sport: .running, steps: (0..<30).map { index in
        WorkoutStep(name: "Step \(index)", intensity: .active, duration: .time(seconds: 60 + index))
    })
    var uploaded = Data()
    link.reply = { frame in
        switch frame.messageType {
        case GFDIMessageID.createFile.rawValue:
            return [GFDICreateFileStatus(result: .ok, fileIndex: 3, dataType: 128, subType: 5, fileNumber: 9).frame()]
        case GFDIMessageID.uploadRequest.rawValue:
            return [GFDIUploadRequestStatus(result: .ok, dataOffset: 0, maxFileSize: 1 << 20, crcSeed: 0).frame()]
        case GFDIMessageID.fileTransferData.rawValue:
            guard let chunk = try? GFDIFileTransferData(frame: frame) else { return [] }
            if Int(chunk.dataOffset) == uploaded.count { uploaded.append(chunk.data) }
            return [GFDIFileTransferDataStatus(transfer: .ok, dataOffset: chunk.dataOffset + UInt32(chunk.data.count)).frame()]
        default:
            return []
        }
    }

    let session = GFDISession(link: link, importer: makeImporter(store), capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { _ in }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    try await session.sendWorkout(plan)

    let createFile = try GFDICreateFile(frame: link.framesSent(of: .createFile)[0])
    #expect(createFile.dataType == 128)
    #expect(createFile.subType == 5)
    #expect(Array(link.framesSent(of: .uploadRequest)[0].payload.prefix(6)) == [3, 0, UInt8(createFile.fileSize & 0xFF),
                                                                              UInt8((createFile.fileSize >> 8) & 0xFF),
                                                                              UInt8((createFile.fileSize >> 16) & 0xFF),
                                                                              UInt8(createFile.fileSize >> 24)])
    #expect(link.framesSent(of: .fileTransferData).count > 1)
    #expect(uploaded.count == Int(createFile.fileSize))
    let decoded = try FitDecoder.decode(uploaded)
    #expect(decoded.messages(26).count == 1)
    #expect(decoded.messages(27).count == 30)
}

/// A zlib stream of one stored block, as the watch sends a file: a two-byte zlib header, then deflate data.
private func zlibStored(_ data: Data) -> Data {
    let length = UInt16(data.count)
    return Data([0x78, 0x01, 0x01, UInt8(length & 0xFF), UInt8(length >> 8),
                 UInt8(~length & 0xFF), UInt8(~length >> 8)]) + data
}

/// A protobuf reply to a phone request, carried in one PROTOBUF_RESPONSE.
private func protobufResponse(_ smart: GarminVivomovehr_Smart) -> GFDIFrame {
    let bytes = try! smart.serializedData()
    return GFDIProtobufResponse(chunk: GFDIProtobufChunk(requestID: 1, dataOffset: 0, totalLength: UInt32(bytes.count),
                                                         data: bytes)).frame()
}

/// Reassembles the phone's protobuf requests as the watch does, so a request larger than one frame is read whole.
@MainActor
private final class ProtobufRequests {
    private var reassembler = GFDIProtobufReassembler()

    /// The request this frame completes, if it is a protobuf request and the last chunk of one.
    func smart(_ frame: GFDIFrame) -> GarminVivomovehr_Smart? {
        guard frame.messageType == GFDIMessageID.protobufRequest.rawValue,
              let request = try? GFDIProtobufRequest(frame: frame),
              let data = try? reassembler.accept(request.chunk) else { return nil }
        return try? GarminVivomovehr_Smart(serializedBytes: data)
    }

    /// Every whole request the link sent, in order.
    static func sent(_ link: FakeLink) -> [GarminVivomovehr_Smart] {
        let requests = ProtobufRequests()
        return link.framesSent(of: .protobufRequest).compactMap { requests.smart($0) }
    }
}

/// The second listing pass: recent health files of Gadgetbridge's pulled types, synced or not.
private func recentListRequest() -> GarminVivomovehr_Smart {
    let synced = GDI_Proto_DataTypes_UUID.with { $0.mostSignificant = 42405; $0.leastSignificant = 42405 }
    var request = GDI_Proto_FileAccess_ItemListRequest()
    request.getFlags = [synced]
    request.includedDataTypes = [4, 9, 15, 28, 32, 35, 38, 41, 44, 49, 52, 57, 58, 61, 66, 68, 70, 71, 72, 73, 74, 77, 79, 82]
        .map { "FIT_TYPE_\($0)" }.sorted().map { name in GDI_Proto_FileAccess_DataType.with { $0.format = .gdxmlDataType; $0.gdxmlString = name } }
    request.requestedMetadata = [.modifiedTime]
    return GarminVivomovehr_Smart.with { $0.fileAccessService.itemListRequest = request }
}

@MainActor
@Test func newSyncListsPullsAndMarksFITFilesSynced() async throws {
    let store = try makeStore()
    let link = FakeLink()
    let fit = activityFIT(ageSeconds: 3600)
    var uid = GDI_Proto_DataTypes_UUID()
    uid.mostSignificant = 0x1111
    uid.leastSignificant = 0x2222
    var fitType = GDI_Proto_FileAccess_DataType()
    fitType.gdxmlString = "FIT_TYPE_4"
    var item = GDI_Proto_FileAccess_ItemReference()
    item.uid = uid
    item.dataType = fitType
    item.dataSize = UInt64(fit.count)

    // The watch lists one FIT file, names transfer handle 5 when it is pulled, and sends the file on that handle.
    link.transferPayloads = [Data([0, 0, 0]), zlibStored(fit)]
    let requests = ProtobufRequests()
    link.reply = { frame in
        guard let smart = requests.smart(frame), smart.hasFileAccessService else { return [] }
        var list = GDI_Proto_FileAccess_ItemListResponse()
        list.status = .success
        list.items = [item]
        var pull = GDI_Proto_FileAccess_PullItemDataResponse()
        pull.result = .success
        pull.transport = .multilinkTransportPipe
        pull.transferHandle = 5
        var service = GDI_Proto_FileAccess_Service()
        if smart.fileAccessService.hasItemListRequest {
            service.itemListResponse = list
        } else if smart.fileAccessService.hasPullItemRequest {
            service.pullItemResponse = pull
        } else {
            return []
        }
        var reply = GarminVivomovehr_Smart()
        reply.fileAccessService = service
        return [protobufResponse(reply)]
    }

    var outputs: [GFDISessionOutput] = []
    let log = ImportLog(store: store)
    let session = GFDISession(link: link, importer: log.importer, capabilities: [], phoneName: "iPhone",
                              newSyncProtocol: true, weatherProvider: nil) { outputs.append($0) }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    await session.requestSync()
    try await waitUntil { outputs.syncFinishes == 1 && log.finishes == 1 }

    // The phone asks for the list, pulls the file, and marks it synced, with exactly these requests.
    var synced = GDI_Proto_DataTypes_UUID()
    synced.mostSignificant = 42405
    synced.leastSignificant = 42405
    var listRequest = GDI_Proto_FileAccess_ItemListRequest()
    listRequest.excludeAllFlags = [synced]
    listRequest.getFlags = [synced]
    var pullRequest = GDI_Proto_FileAccess_PullItemDataRequest()
    pullRequest.item = item
    pullRequest.priority = 24
    pullRequest.supportedTransports = [.multilinkTransportPipe]
    pullRequest.offset = 0
    pullRequest.requestedCompressionWindow = 15
    var modify = GDI_Proto_FileAccess_ModifyFlagsRequest()
    modify.uid = uid
    modify.setFlags = [synced]
    var listService = GDI_Proto_FileAccess_Service()
    listService.itemListRequest = listRequest
    var pullService = GDI_Proto_FileAccess_Service()
    pullService.pullItemRequest = pullRequest
    var modifyService = GDI_Proto_FileAccess_Service()
    modifyService.modifyFlagsRequest = modify
    var expected = [listService, pullService, modifyService].map { service -> GarminVivomovehr_Smart in
        var smart = GarminVivomovehr_Smart()
        smart.fileAccessService = service
        return smart
    }
    // The recent pass follows the first list; its items carry no modified time here, so it adds nothing.
    expected.insert(recentListRequest(), at: 1)
    #expect(ProtobufRequests.sent(link) == expected)

    // The file is read from transfer handle 5 with the phone's request, and it is not downloaded the legacy way.
    #expect(link.transfers.map(\.requests) == [[Data([0, 0, 5, 0, 0, 0])]])
    #expect(link.framesSent(of: .downloadRequest).isEmpty)

    #expect(log.imported.map { $0.steps.map(\.value) } == [[50]])
    #expect(log.history.steps.map(\.value) == [50])
}

/// The profile below as a settings file, with time_created 1800000000 (Unix). Derived by hand from Gadgetbridge's
/// FIT rules: big-endian values, local type 0 with a definition per message, and the FIT profile's scales and
/// offsets. Born 1987, male, 176 cm (176), 81.3 kg (813), units imperial (1), resting 52, max 191, 12 h (0),
/// sleep 23:15 (83700 s), wake 06:40 (24000 s).
private let profileSettingsFile = "0e107d52790000002e464954d27940000100000600010001028402028404048603048c05028400020001fffe45ac860000000001000140000100030e0101000301020402840601000701000801020b01020d01000e01001501001801021c04861d04861e01000001b0032d010134bf0101015700005dc0000146f40140000100020104010000003379"

private func asymmetricProfile() -> UserProfile {
    UserProfile(birthDate: Calendar.current.date(from: DateComponents(year: 1987, month: 3, day: 9)),
                gender: .male, heightCm: 176, weightKg: 81.3, restingHeartRate: 52, maxHeartRate: 191,
                usesMetricUnits: false, uses24HourTime: false,
                sleepTime: DateComponents(hour: 23, minute: 15), wakeTime: DateComponents(hour: 6, minute: 40))
}

/// A watch that accepts a file upload: the create, the upload request and every chunk are acknowledged.
@MainActor
private func acceptsUpload(_ frame: GFDIFrame) -> [GFDIFrame] {
    switch frame.messageType {
    case GFDIMessageID.createFile.rawValue:
        return [GFDICreateFileStatus(result: .ok, fileIndex: 3, dataType: 128, subType: 2, fileNumber: 9).frame()]
    case GFDIMessageID.uploadRequest.rawValue:
        return [GFDIUploadRequestStatus(result: .ok, dataOffset: 0, maxFileSize: 1 << 20, crcSeed: 0).frame()]
    case GFDIMessageID.fileTransferData.rawValue:
        guard let chunk = try? GFDIFileTransferData(frame: frame) else { return [] }
        return [GFDIFileTransferDataStatus(transfer: .ok, dataOffset: chunk.dataOffset + UInt32(chunk.data.count)).frame()]
    default:
        return []
    }
}

@MainActor
@Test func profileUploadSendsTheSettingsFileInGadgetbridgeFrames() async throws {
    let store = try makeStore()
    let link = FakeLink()
    link.reply = acceptsUpload
    let session = GFDISession(link: link, importer: makeImporter(store), capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { _ in }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    try await session.sendProfile(asymmetricProfile(), now: Date(timeIntervalSince1970: 1_800_000_000))
    try await waitUntil { link.sent.count == 4 }

    let file = try #require(Data(hex: profileSettingsFile))
    let sent = link.sent
    #expect(sent.map(\.messageType) == [GFDIMessageID.createFile.rawValue, GFDIMessageID.uploadRequest.rawValue,
                                        GFDIMessageID.fileTransferData.rawValue, GFDIMessageID.systemEvent.rawValue])
    // CREATE_FILE: size, type 128, sub type 2 (settings), index 0, reserved, masks, path length 0, then the random file ID.
    #expect(sent[0].payload.count == 22)
    #expect(Array(sent[0].payload.prefix(14)) == [0x89, 0x00, 0x00, 0x00, 0x80, 0x02, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00])
    // UPLOAD_REQUEST: the index the watch gave, the size, offset 0 and CRC seed 0.
    #expect(Array(sent[1].payload) == [0x03, 0x00, 0x89, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    // FILE_TRANSFER_DATA: flags, the running CRC over the chunk (0, because the file ends with its own CRC), offset 0, the file.
    #expect(Array(sent[2].payload) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] + Array(file))
    // SYSTEM_EVENT sync complete ends the upload.
    #expect(Array(sent[3].payload) == [0x00, 0x00])
}

@MainActor
@Test func handshakeSendsTheStoredProfileAsSettingsFile() async throws {
    let store = try makeStore()
    store.pairedWatch = PairedWatch(id: UUID(), name: "Venu 4", catalogID: "garmin_venu_4")
    store.userProfile = asymmetricProfile()
    let link = FakeLink()
    link.reply = acceptsUpload
    link.watchSends(deviceInformationFrame())
    link.watchSends(GFDIConfiguration(capabilities: [.sync, .gncs, .findMyWatch]).frame())

    let service = GarminWatchService(store: store, makeLink: { _ in link })
    try await waitUntil { link.framesSent(of: .createFile).count == 1 }

    let createFile = try GFDICreateFile(frame: link.framesSent(of: .createFile)[0])
    #expect(createFile.dataType == 128)
    #expect(createFile.subType == 2)
    #expect(createFile.fileSize == 137)
    #expect(service.pairedWatch?.name == "Venu 4")
}

private extension Array where Element == GFDISessionOutput {
    var syncFinishes: Int {
        filter { output in
            if case .syncFinished = output { return true }
            return false
        }.count
    }
}

/// As a Venu 4 lists files: only the first item of a type names it, later ones carry only its key, and files
/// Gadgetbridge does not pull (here settings, FIT_TYPE_2) are listed alongside.
@MainActor
@Test func newSyncResolvesTypeKeysAndPullsOnlyGadgetbridgesTypes() async throws {
    let store = try makeStore()
    let link = FakeLink()
    func item(_ least: UInt64, name: String?, key: UInt32) -> GDI_Proto_FileAccess_ItemReference {
        var item = GDI_Proto_FileAccess_ItemReference()
        item.uid = GDI_Proto_DataTypes_UUID.with { $0.mostSignificant = 7; $0.leastSignificant = least }
        item.dataType = GDI_Proto_FileAccess_DataType.with {
            if let name { $0.gdxmlString = name }
            $0.gdxmlStringKey = key
        }
        item.dataSize = 100
        return item
    }
    let named = item(1, name: "FIT_TYPE_32", key: 21)
    let keyOnly = item(2, name: nil, key: 21)
    let settings = item(3, name: "FIT_TYPE_2", key: 4)
    let unknownKey = item(4, name: nil, key: 99)

    link.transferPayloads = [Data([0, 0, 0]), zlibStored(activityFIT(ageSeconds: 3600))]
    let requests = ProtobufRequests()
    link.reply = { frame in
        guard let smart = requests.smart(frame), smart.hasFileAccessService else { return [] }
        var service = GDI_Proto_FileAccess_Service()
        if smart.fileAccessService.hasItemListRequest {
            service.itemListResponse = GDI_Proto_FileAccess_ItemListResponse.with {
                $0.status = .success
                $0.items = [named, settings, keyOnly, unknownKey]
            }
        } else if smart.fileAccessService.hasPullItemRequest {
            service.pullItemResponse = GDI_Proto_FileAccess_PullItemDataResponse.with {
                $0.result = .success
                $0.transport = .multilinkTransportPipe
                $0.transferHandle = 5
            }
        } else {
            return []
        }
        return [protobufResponse(GarminVivomovehr_Smart.with { $0.fileAccessService = service })]
    }

    var outputs: [GFDISessionOutput] = []
    let log = ImportLog(store: store)
    let session = GFDISession(link: link, importer: log.importer, capabilities: [], phoneName: "iPhone",
                              newSyncProtocol: true, weatherProvider: nil) { outputs.append($0) }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    await session.requestSync()
    try await waitUntil { outputs.syncFinishes == 1 }

    let services = ProtobufRequests.sent(link).map(\.fileAccessService)
    let pulled = services.filter(\.hasPullItemRequest).map(\.pullItemRequest.item)
    // Both monitoring files are pulled, the key-only one with its resolved name; settings and the unknown key are not.
    #expect(pulled.map(\.uid.leastSignificant) == [1, 2])
    #expect(pulled.map(\.dataType.gdxmlString) == ["FIT_TYPE_32", "FIT_TYPE_32"])
    let marked = services.filter(\.hasModifyFlagsRequest).map(\.modifyFlagsRequest.uid.leastSignificant)
    #expect(marked == [1, 2])
}
