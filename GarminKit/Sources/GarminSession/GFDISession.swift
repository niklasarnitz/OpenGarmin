import Foundation
import GarminCore
import GarminFIT
import GarminModels
import GarminProtobuf
import GarminProtocol
import GarminTransport
import SwiftProtobuf

/// What a session reports to the service that owns it.
enum GFDISessionOutput: Sendable {
    /// The handshake finished: the watch has identified itself and sent its capabilities.
    case ready(DeviceInfo?, Set<GarminCapability>)
    case progress(Double, String)
    case syncFinished
    case event(WatchEvent)
}

/// Protocol engine for one watch on one link: handshake, file sync, uploads, weather, notifications, find my
/// watch and protobuf services. Frames are handled one at a time, in arrival order, so replies go out in the
/// order the watch expects. The service owns the link and the connection; this type owns the protocol.
@MainActor
final class GFDISession {
    /// Gadgetbridge's OUR_CAPABILITIES: every capability except the ones it does not implement.
    static let phoneCapabilities = Set(GarminCapability.allCases).subtracting([
        .gpsEphemerisDownload, .livetrack, .livetrackAutoStart,
        .capability104, .capability105, .capability106, .capability107, .capability108, .capability109,
        .capability110, .capability111, .capability114, .capability115, .capability116, .capability117,
        .capability118, .capability119,
    ])

    private static let defaultMaxPacketSize = 375
    private static let uploadTimeout: Duration = .seconds(120)

    private let link: any GarminLink
    private let store: SessionStore
    private let capabilities: Set<GarminCapability>
    private let phoneName: String
    private let weatherProvider: (@MainActor () async -> WeatherReport?)?
    private let output: @MainActor (GFDISessionOutput) -> Void

    private var deviceInfo: DeviceInfo?
    private var maxPacketSize = GFDISession.defaultMaxPacketSize
    private var watchCapabilities: Set<GarminCapability> = []
    private var calendarEvents: [CalendarEvent] = []
    private var notifications: [Int32: PhoneNotification] = [:]
    private var reassembler = GFDIProtobufReassembler()
    private var protobufRequestID: UInt16 = 0

    private var isSyncing = false
    private var pending: [WatchFile] = []
    private var download: Download?
    private var syncTotal = 0
    private var syncDone = 0
    private var upload: Upload?

    /// A file the watch can hand over, from a directory entry or a FILE_AVAILABLE message.
    fileprivate struct WatchFile: Sendable {
        var index: UInt16
        var dataType: UInt8
        var subType: UInt8
        var fileNumber: UInt16
        var size: UInt32
        var timestamp: UInt32

        /// FIT files are data type 128.
        var isFIT: Bool { dataType == 128 }
    }

    private struct Download {
        /// nil for the root directory.
        var file: WatchFile?
        /// Known once the watch accepts the request.
        var size: Int?
        var data = Data()
    }

    private struct Upload {
        let id: UUID
        let data: Data
        var fileIndex: UInt16 = 0
        var offset = 0
        var crc: UInt16 = 0
        let continuation: CheckedContinuation<Void, Error>
    }

    init(link: any GarminLink, store: SessionStore, capabilities: Set<GarminCapability>, phoneName: String,
         weatherProvider: (@MainActor () async -> WeatherReport?)?,
         output: @escaping @MainActor (GFDISessionOutput) -> Void) {
        self.link = link
        self.store = store
        self.capabilities = capabilities
        self.phoneName = phoneName
        self.weatherProvider = weatherProvider
        self.output = output
    }

    /// The link dropped: fail any upload in flight and forget the sync.
    func disconnected() {
        finishUpload(.failure(GarminWatchError.notConnected))
        download = nil
        pending = []
        isSyncing = false
    }

    // MARK: - Receiving

    func receive(_ data: Data) async {
        guard let frame = try? GFDIFrame.decode(data) else { return }
        switch GFDIMessageParser.parse(frame) {
        case let message as GFDIDeviceInformation:
            deviceInfo = message.deviceInfo
            if message.maxPacketSize > 0 { maxPacketSize = message.maxPacketSize }
            await send(message.acknowledgement(phoneName: phoneName, manufacturer: "Apple", model: phoneName))
        case let message as GFDIConfiguration:
            await send(message.acknowledgement())
            watchCapabilities = message.capabilities
            await send(GFDIConfiguration(capabilities: capabilities))
            await completeHandshake()
        case let message as GFDICurrentTimeRequest:
            await send(message.acknowledgement())
        case let message as GFDISynchronization:
            await send(message.acknowledgement())
            if message.kind == .manual || message.contains(.activities) || message.contains(.workouts)
                || message.contains(.sleep) || message.contains(.activitySummary) {
                await requestSync()
            }
        case let message as GFDIBatteryStatus:
            await send(message.acknowledgement())
            output(.event(.battery(BatteryStatus(percent: message.percent, isCharging: false))))
        case let message as GFDIFileAvailable:
            await send(message.acknowledgement())
            await enqueue(WatchFile(message))
        case let message as GFDIFileTransferData:
            await send(message.acknowledgement())
            await receiveDownloadChunk(message.data)
        case let message as GFDIDownloadRequestStatus:
            await receiveDownloadStatus(message)
        case let message as GFDIFileTransferDataStatus:
            await receiveUploadStatus(message)
        case let message as GFDIUploadRequestStatus:
            await receiveUploadRequestStatus(message)
        case let message as GFDICreateFileStatus:
            await receiveCreateFileStatus(message)
        case let message as GFDIFindMyPhoneRequest:
            await send(message.acknowledgement())
            output(.event(.findMyPhone(started: true)))
        case let message as GFDIFindMyPhoneCancel:
            await send(message.acknowledgement())
            output(.event(.findMyPhone(started: false)))
        case let message as GFDIWeatherRequest:
            await send(message.acknowledgement())
            Task { [weak self] in
                guard let provider = self?.weatherProvider, let report = await provider() else { return }
                try? await self?.sendWeather(report)
            }
        case let message as GFDIAuthNegotiation:
            await send(message.acknowledgement())
        case let message as GFDINotificationControl:
            await receiveNotificationControl(message)
        case let message as GFDINotificationSubscription:
            await send(message.acknowledgement(sendsAppNotifications: true))
        case let message as GFDIMusicControl:
            await send(message.acknowledgement())
        case let message as GFDIMusicControlCapabilities:
            await send(message.acknowledgement())
        case let message as GFDIFitDefinition:
            await send(message.acknowledgement())
        case let message as GFDIFitData:
            await send(message.acknowledgement())
        case let message as GFDIProtobufRequest:
            await receiveProtobuf(message.chunk, ack: message.acknowledgement())
        case let message as GFDIProtobufResponse:
            await receiveProtobuf(message.chunk, ack: message.acknowledgement())
        default:
            break
        }
    }

    // MARK: - Handshake

    private func completeHandshake() async {
        await send(GFDISupportedFileTypesRequest())
        await send(GFDISetDeviceSettings(settings: [
            .autoUploadEnabled: .bool(true),
            .weatherConditionsEnabled: .bool(true),
            .weatherAlertsEnabled: .bool(false),
        ]))
        await send(GFDISystemEvent(.timeUpdated))
        await send(GFDISystemEvent(.syncReady))
        try? await sendProtobufRequest(Self.batteryStatusRequest())
        for kind in [GFDISystemEvent.Kind.pairComplete, .syncComplete, .setupWizardComplete] {
            await send(GFDISystemEvent(kind))
        }
        output(.ready(deviceInfo, watchCapabilities))
    }

    func setTime() async throws {
        try await transmit(GFDISystemEvent(.timeUpdated))
    }

    // MARK: - Phone to watch

    func findMyWatch() async throws {
        var request = GDI_Proto_FindMyWatch_FindMyWatchRequest()
        request.timeout = 60
        var service = GDI_Proto_FindMyWatch_FindMyWatchService()
        service.findRequest = request
        var smart = GarminVivomovehr_Smart()
        smart.findMyWatchService = service
        try await sendProtobufRequest(smart)
    }

    func setCalendar(_ events: [CalendarEvent]) {
        calendarEvents = events
    }

    func sendWeather(_ report: WeatherReport) async throws {
        let payload = WeatherFitEncoder.encode(report)
        try await transmit(GFDIFitDefinition(data: payload.definitions))
        try await transmit(GFDIFitData(data: payload.data))
    }

    func sendNotification(_ notification: PhoneNotification) async throws {
        let key = Int32(truncatingIfNeeded: notification.id)
        let kind: GFDINotificationUpdate.Kind = notifications[key] == nil ? .add : .modify
        notifications[key] = notification
        try await transmit(GFDINotificationUpdate(
            kind: kind, flags: [.foreground], category: .other,
            count: UInt8(min(notifications.count, 255)), notificationID: key, phoneFlags: []
        ))
    }

    /// The watch asked for the text of a notification it was told about. The text goes out as NOTIFICATION_DATA.
    private func receiveNotificationControl(_ message: GFDINotificationControl) async {
        await send(message.acknowledgement())
        guard case let .notificationAttributes(id, attributes) = message.request,
              let notification = notifications[id] else { return }

        var writer = ByteWriter()
        writer.writeUInt8(0) // GET_NOTIFICATION_ATTRIBUTES
        writer.writeInt32(id)
        for requested in attributes {
            var value = Array(Self.attributeText(requested.attribute, of: notification).utf8)
            if requested.maxLength > 0 { value = Array(value.prefix(Int(requested.maxLength))) }
            writer.writeUInt8(requested.attribute.rawValue)
            writer.writeUInt16(UInt16(value.count))
            writer.writeBytes(value)
        }
        let bytes = writer.bytes
        var crc: UInt16 = 0
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 200, bytes.count)
            crc = GarminCRC.compute(bytes[offset..<end], seed: crc)
            await send(GFDINotificationData(messageSize: UInt16(bytes.count), crc: crc,
                                            dataOffset: UInt16(offset), chunk: Data(bytes[offset..<end])))
            offset = end
        }
    }

    private static func attributeText(_ attribute: GFDINotificationAttribute, of notification: PhoneNotification) -> String {
        switch attribute {
        case .appIdentifier: notification.appIdentifier
        case .title: notification.title
        case .subtitle: notification.subtitle ?? ""
        case .message: notification.body
        case .messageSize: String(notification.body.utf8.count)
        default: ""
        }
    }

    func sendWorkout(_ plan: WorkoutPlan) async throws {
        guard upload == nil else { throw GarminWatchError.busy }
        let data = WorkoutFitEncoder.encode(plan)
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            upload = Upload(id: id, data: data, continuation: continuation)
            Task {
                do {
                    try await self.transmit(GFDICreateFile(
                        fileSize: UInt32(data.count), dataType: 128, subType: 5,
                        fileID: UInt64.random(in: .min ... .max)
                    ))
                } catch {
                    self.finishUpload(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: Self.uploadTimeout)
                if self.upload?.id == id { self.finishUpload(.failure(GarminWatchError.timedOut)) }
            }
        }
    }

    // MARK: - File sync (watch to phone)

    /// Starts a sync: the root directory is requested, then every FIT file it lists that is not imported yet.
    func requestSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncTotal = 0
        syncDone = 0
        download = Download(file: nil)
        output(.progress(0, "Listing activities"))
        await send(GFDIDownloadRequest(fileIndex: 0, dataOffset: 0, mode: .new, crcSeed: 0, dataSize: 0))
    }

    private func enqueue(_ file: WatchFile) async {
        guard file.isFIT else { return }
        isSyncing = true
        pending.append(file)
        syncTotal += 1
        await processQueue()
    }

    private func receiveDownloadStatus(_ status: GFDIDownloadRequestStatus) async {
        guard let current = download, current.size == nil else { return }
        guard status.result == .ok else {
            download = nil
            await processQueue()
            return
        }
        download?.size = Int(status.maxFileSize)
        if status.maxFileSize == 0 { await completeDownload() }
    }

    private func receiveDownloadChunk(_ data: Data) async {
        guard download?.size != nil else { return }
        download?.data.append(data)
        if let finished = download, let size = finished.size, finished.data.count >= size {
            await completeDownload()
        }
    }

    private func completeDownload() async {
        guard let finished = download, let size = finished.size else { return }
        download = nil
        let bytes = Data(finished.data.prefix(size))
        if let file = finished.file {
            await importFile(file, bytes: bytes)
        } else {
            let files = Self.directoryEntries(bytes).filter { $0.isFIT }
            pending += files
            syncTotal += files.count
        }
        await processQueue()
    }

    /// Starts the next download that is not already imported. Imported files are only archived on the watch.
    private func processQueue() async {
        guard download == nil else { return }
        while !pending.isEmpty {
            let file = pending.removeFirst()
            syncDone += 1
            if store.isImported(key(file)) {
                await archive(file)
                continue
            }
            download = Download(file: file)
            output(.progress(Double(syncDone) / Double(max(syncTotal, 1)), "Downloading activity \(syncDone) of \(syncTotal)"))
            await send(GFDIDownloadRequest(fileIndex: file.index, dataOffset: 0, mode: .new, crcSeed: 0, dataSize: 0))
            return
        }
        await finishSync()
    }

    private func importFile(_ file: WatchFile, bytes: Data) async {
        let batch: HealthBatch
        do {
            batch = FitExtractor.extract(try FitDecoder.decode(bytes), unitNumber: deviceInfo?.unitNumber)
        } catch {
            // A file that does not decode would be fetched again on every sync, so it is recorded as imported.
            output(.event(.log("Skipped FIT file \(file.index): \(error)")))
            try? store.markImported(key(file))
            await archive(file)
            return
        }
        do {
            try store.record(batch, fileKey: key(file), fit: bytes)
        } catch {
            // Not archived, so the watch lists it again and the next sync retries.
            output(.event(.log("Could not store FIT file \(file.index): \(error)")))
            return
        }
        output(.event(.healthBatchImported(batch)))
        await archive(file)
    }

    private func finishSync() async {
        guard isSyncing else { return }
        isSyncing = false
        await send(GFDISystemEvent(.syncComplete))
        output(.syncFinished)
    }

    private func archive(_ file: WatchFile) async {
        await send(GFDISetFileFlags(fileIndex: file.index, flags: .archive))
    }

    private func key(_ file: WatchFile) -> String {
        "\(deviceInfo?.unitNumber ?? 0)-\(file.index)-\(file.timestamp)-\(file.size)"
    }

    private static func directoryEntries(_ data: Data) -> [WatchFile] {
        var reader = ByteReader(data)
        var files: [WatchFile] = []
        while reader.remaining >= 16, let file = try? WatchFile(directoryEntry: &reader) {
            files.append(file)
        }
        return files
    }

    // MARK: - Upload (phone to watch)

    private func receiveCreateFileStatus(_ status: GFDICreateFileStatus) async {
        guard var current = upload else { return }
        guard status.result == .ok else {
            finishUpload(.failure(GarminWatchError.uploadFailed("the watch refused the file: \(status.result)")))
            return
        }
        current.fileIndex = status.fileIndex
        upload = current
        await send(GFDIUploadRequest(fileIndex: status.fileIndex, size: UInt32(current.data.count)))
    }

    private func receiveUploadRequestStatus(_ status: GFDIUploadRequestStatus) async {
        guard var current = upload else { return }
        guard status.result == .ok else {
            finishUpload(.failure(GarminWatchError.uploadFailed("the watch refused the transfer: \(status.result)")))
            return
        }
        current.offset = Int(status.dataOffset)
        upload = current
        await sendNextUploadChunk()
    }

    private func receiveUploadStatus(_ status: GFDIFileTransferDataStatus) async {
        guard var current = upload else { return }
        guard status.transfer == .ok else {
            finishUpload(.failure(GarminWatchError.uploadFailed("the watch stopped the transfer: \(status.transfer)")))
            return
        }
        current.offset = Int(status.dataOffset)
        upload = current
        await sendNextUploadChunk()
    }

    /// Sends the chunk at the watch's offset, or completes the upload once the watch has the whole file.
    private func sendNextUploadChunk() async {
        guard var current = upload else { return }
        if current.offset >= current.data.count {
            finishUpload(.success(()))
            await send(GFDISystemEvent(.syncComplete))
            return
        }
        let end = min(current.offset + max(1, maxPacketSize - 13), current.data.count)
        let chunk = current.data.subdata(in: current.offset..<end)
        current.crc = GarminCRC.compute(chunk, seed: current.crc)
        let frame = GFDIFileTransferData(crc: current.crc, dataOffset: UInt32(current.offset), data: chunk)
        current.offset = end
        upload = current
        await send(frame)
    }

    private func finishUpload(_ result: Result<Void, Error>) {
        guard let finished = upload else { return }
        upload = nil
        finished.continuation.resume(with: result)
    }

    // MARK: - Protobuf services

    private static func batteryStatusRequest() -> GarminVivomovehr_Smart {
        var status = GDI_Proto_DeviceStatus_DeviceStatusService()
        status.remoteDeviceBatteryStatusRequest = GDI_Proto_DeviceStatus_RemoteDeviceBatteryStatusRequest()
        var smart = GarminVivomovehr_Smart()
        smart.deviceStatusService = status
        return smart
    }

    private func receiveProtobuf(_ chunk: GFDIProtobufChunk, ack: GFDIResponse) async {
        await send(ack)
        let complete: Data?
        do {
            complete = try reassembler.accept(chunk)
        } catch {
            return
        }
        guard let bytes = complete, let smart = try? GarminVivomovehr_Smart(serializedBytes: bytes) else { return }
        if smart.hasCalendarEventsService, let response = calendarResponse(smart.calendarEventsService) {
            await sendProtobufResponse(response, requestID: chunk.requestID)
        }
        if smart.hasDeviceStatusService, smart.deviceStatusService.hasRemoteDeviceBatteryStatusResponse {
            let status = smart.deviceStatusService.remoteDeviceBatteryStatusResponse
            let charging = status.batteryStatus == .charging || status.batteryStatus == .fullyCharged
            output(.event(.battery(BatteryStatus(percent: Int(status.currentBatteryLevel), isCharging: charging))))
        }
    }

    /// Answers a watch calendar request with the pushed events in the requested range.
    private func calendarResponse(_ calendar: GDI_Proto_Calendar_CalendarService) -> GarminVivomovehr_Smart? {
        guard calendar.hasCalendarEventsRequest else { return nil }
        let request = calendar.calendarEventsRequest
        let limit = Int(request.maxEvents) * 2
        var events: [GDI_Proto_Calendar_CalendarEvent] = []
        for event in calendarEvents.sorted(by: { $0.start < $1.start }) where events.count < limit {
            let start = UInt64(GarminTime.garminSeconds(from: event.start))
            let end = UInt64(GarminTime.garminSeconds(from: event.end))
            guard end >= request.startDate, start <= request.endDate else { continue }
            guard request.includeAllDay || !event.isAllDay else { continue }
            var item = GDI_Proto_Calendar_CalendarEvent()
            item.title = String(event.title.prefix(Int(request.maxTitleLength)))
            item.startDate = start
            item.endDate = end
            item.allDay = event.isAllDay
            if request.includeLocation, let location = event.location {
                item.location = String(location.prefix(Int(request.maxLocationLength)))
            }
            events.append(item)
        }
        var response = GDI_Proto_Calendar_CalendarEventsResponse()
        response.events = events
        response.status = .ok
        var service = GDI_Proto_Calendar_CalendarService()
        service.calendarEventsResponse = response
        var smart = GarminVivomovehr_Smart()
        smart.calendarEventsService = service
        return smart
    }

    private func sendProtobufRequest(_ smart: GarminVivomovehr_Smart) async throws {
        protobufRequestID &+= 1
        for chunk in try Self.chunks(smart, requestID: protobufRequestID, maxPacketSize: maxPacketSize) {
            try await transmit(GFDIProtobufRequest(chunk: chunk))
        }
    }

    private func sendProtobufResponse(_ smart: GarminVivomovehr_Smart, requestID: UInt16) async {
        guard let chunks = try? Self.chunks(smart, requestID: requestID, maxPacketSize: maxPacketSize) else { return }
        for chunk in chunks {
            await send(GFDIProtobufResponse(chunk: chunk))
        }
    }

    private static func chunks(_ smart: GarminVivomovehr_Smart, requestID: UInt16, maxPacketSize: Int) throws -> [GFDIProtobufChunk] {
        GFDIProtobufChunk.split(requestID: requestID, bytes: try smart.serializedData(),
                                maxChunkSize: max(16, maxPacketSize - 20))
    }

    // MARK: - Writing

    private func transmit(_ message: some GFDIOutgoing) async throws {
        try await link.send(message.frame().encoded())
    }

    /// A send that fails only when the link is gone, which the service sees as a drop, so the error is not kept.
    private func send(_ message: some GFDIOutgoing) async {
        try? await transmit(message)
    }
}

extension GFDISession.WatchFile {
    /// Reads one 16-byte directory entry (little endian), as Gadgetbridge's FileTransferHandler does.
    init(directoryEntry reader: inout ByteReader) throws {
        index = try reader.readUInt16()
        dataType = try reader.readUInt8()
        subType = try reader.readUInt8()
        fileNumber = try reader.readUInt16()
        try reader.skip(2) // specific and file flags
        size = try reader.readUInt32()
        timestamp = try reader.readUInt32()
    }

    init(_ available: GFDIFileAvailable) {
        index = available.fileIndex
        dataType = available.dataType
        subType = available.subType
        fileNumber = available.fileNumber
        size = available.fileSize
        timestamp = available.date.map { GarminTime.garminSeconds(from: $0) } ?? 0
    }
}
