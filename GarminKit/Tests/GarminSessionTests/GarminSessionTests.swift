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
private func makeStore() throws -> SessionStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    return try SessionStore(directory: directory, defaults: defaults)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within 5 seconds")
}

/// DEVICE_INFORMATION as a Venu-style watch sends it: protocol 2.00, no Bluetooth MAC.
private func deviceInformationFrame() -> GFDIFrame {
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
private func activityFIT() -> Data {
    let start = Int64(GarminTime.garminSeconds(from: .now)) - 3600
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

@MainActor
@Test func directorySyncDownloadsNewFITFilesAndArchivesThem() async throws {
    let store = try makeStore()
    let link = FakeLink()
    let fit = activityFIT()
    let listing = directoryEntry(index: 7, dataType: 128, subType: 4, size: fit.count, timestamp: 1000)
        + directoryEntry(index: 9, dataType: 255, subType: 245, size: 10, timestamp: 1000) // not a FIT file
    let files: [UInt16: Data] = [0: listing, 7: fit]
    link.reply = { frame in
        guard frame.messageType == GFDIMessageID.downloadRequest.rawValue else { return [] }
        let data = files[fileIndex(frame)] ?? Data()
        return [
            GFDIDownloadRequestStatus(result: .ok, maxFileSize: UInt32(data.count)).frame(),
            GFDIFileTransferData(crc: 0, dataOffset: 0, data: data).frame(),
        ]
    }

    var outputs: [GFDISessionOutput] = []
    let session = GFDISession(link: link, store: store, capabilities: [], phoneName: "iPhone",
                              weatherProvider: nil) { outputs.append($0) }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    await session.requestSync()
    try await waitUntil { outputs.syncFinishes == 1 }

    let imported = outputs.compactMap { output -> HealthBatch? in
        if case let .event(.healthBatchImported(batch)) = output { return batch }
        return nil
    }
    #expect(imported.map { $0.steps.map(\.value) } == [[50]])
    #expect(store.history.steps.map(\.value) == [50])
    // The listing is requested, then only the FIT file, never the non-FIT entry.
    #expect(link.framesSent(of: .downloadRequest).map(fileIndex) == [0, 7])
    // The FIT file is archived on the watch: file index 7, flags ARCHIVE (0x10).
    #expect(link.framesSent(of: .setFileFlag).map { Array($0.payload) } == [[7, 0, 0x10]])

    // A second sync lists the same file, which is already imported, so it is archived without a download.
    await session.requestSync()
    try await waitUntil { outputs.syncFinishes == 2 }
    #expect(link.framesSent(of: .downloadRequest).map(fileIndex) == [0, 7, 0])
    #expect(outputs.filter { if case .event(.healthBatchImported) = $0 { true } else { false } }.count == 1)
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

    let session = GFDISession(link: link, store: store, capabilities: [], phoneName: "iPhone",
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

@MainActor
@Test func newSyncListsPullsAndMarksFITFilesSynced() async throws {
    let store = try makeStore()
    let link = FakeLink()
    let fit = activityFIT()
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
    link.reply = { frame in
        guard frame.messageType == GFDIMessageID.protobufRequest.rawValue,
              let request = try? GFDIProtobufRequest(frame: frame),
              let smart = try? GarminVivomovehr_Smart(serializedBytes: request.chunk.data),
              smart.hasFileAccessService else { return [] }
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
    let session = GFDISession(link: link, store: store, capabilities: [], phoneName: "iPhone",
                              newSyncProtocol: true, weatherProvider: nil) { outputs.append($0) }
    let pump = Task { for await frame in link.incomingFrames { await session.receive(frame) } }
    defer { pump.cancel() }

    await session.requestSync()
    try await waitUntil { outputs.syncFinishes == 1 }

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
    let expected = [listService, pullService, modifyService].map { service -> GarminVivomovehr_Smart in
        var smart = GarminVivomovehr_Smart()
        smart.fileAccessService = service
        return smart
    }
    let sent = try link.framesSent(of: .protobufRequest).map { frame -> GarminVivomovehr_Smart in
        let request = try GFDIProtobufRequest(frame: frame)
        return try GarminVivomovehr_Smart(serializedBytes: request.chunk.data)
    }
    #expect(sent == expected)

    // The file is read from transfer handle 5 with the phone's request, and it is not downloaded the legacy way.
    #expect(link.transfers.map(\.requests) == [[Data([0, 0, 5, 0, 0, 0])]])
    #expect(link.framesSent(of: .downloadRequest).isEmpty)

    let imported = outputs.compactMap { output -> HealthBatch? in
        if case let .event(.healthBatchImported(batch)) = output { return batch }
        return nil
    }
    #expect(imported.map { $0.steps.map(\.value) } == [[50]])
    #expect(store.history.steps.map(\.value) == [50])
}

private extension Array where Element == GFDISessionOutput {
    var syncFinishes: Int {
        filter { output in
            if case .syncFinished = output { return true }
            return false
        }.count
    }
}
