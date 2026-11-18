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
    /// The current file's download progress; nil once no file is downloading.
    case fileProgress(FileTransferProgress?)
    case installedApps([InstalledApp])
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
    /// FIT file types (the directory entry's sub type, or the FIT_TYPE_ item type): 4 is an activity. Only activities
    /// count towards the sync notification.
    private static let activityFileType: UInt8 = 4
    private static let activityItemType = "FIT_TYPE_4"

    private typealias Item = GDI_Proto_FileAccess_ItemReference

    private let link: any GarminServiceLink
    private let importer: FITImporter
    private let capabilities: Set<GarminCapability>
    private let phoneName: String
    /// The catalog's choice for this model. nil when the catalog does not know the model.
    private let newSyncProtocol: Bool?
    private let weatherProvider: (@MainActor () async -> WeatherReport?)?
    private let http: WatchHTTPService
    let output: @MainActor (GFDISessionOutput) -> Void

    private var deviceInfo: DeviceInfo?
    private var maxPacketSize = GFDISession.defaultMaxPacketSize
    private var watchCapabilities: Set<GarminCapability> = []
    private var calendarEvents: [CalendarEvent] = []
    /// Notifications the app has sent and the watch still shows. Managed in GFDISession+Notifications.swift.
    var notifications: [Int32: PhoneNotification] = [:]
    /// The settings screen read and the settings change in flight, managed in GFDISession+Settings.swift.
    var settingsRead: SettingsRead?
    var settingsChange: SettingsChange?
    private var reassembler = GFDIProtobufReassembler()
    private var protobufRequestID: UInt16 = 0

    private var isSyncing = false
    private var pending: [WatchFile] = []
    private var download: Download?
    private var syncTotal = 0
    private var syncDone = 0
    /// Activities imported by the current sync, reported to the watch as a notification when it ends.
    private var syncedActivities = 0
    private var upload: Upload?

    // New sync protocol: the files are listed and pulled as protobuf messages, and their bytes arrive on a file transfer service.
    private var listing = false
    /// New-sync watches first get the legacy directory request, as in Gadgetbridge: it flushes the monitoring files,
    /// and its directory also lists health files Garmin Connect already synced, which the new listing hides.
    private var legacyFirst = false
    /// The second listing pass of a connection: recent health files, including ones another app (Garmin Connect)
    /// already marked synced, which the first pass excludes.
    private var listingRecent = false
    private var recentPassDone = false
    /// Whether the watch accepts `included_data_types`; the Venu 4 answers FAIL_INVALID_DATA_TYPE to plain names.
    private var recentTypeFilter = true
    private var recentPages = 0
    static let maxRecentPages = 30
    static let recentWindow: TimeInterval = 7 * 86_400
    private var nextTransactionID: UInt32?
    private var pendingItems: [Item] = []
    private var currentItem: Item?
    private var transferTask: Task<Void, Never>?

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

    private var lastFileProgressStep = -1

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
        var onProgress: (@MainActor (Double) -> Void)?
    }

    /// - Parameter importer: the import stage that keeps the downloaded files. It outlives the session.
    /// - Parameter newSyncProtocol: whether the new sync protocol is used. nil decides from the watch's capabilities.
    /// - Parameter agps: answers the watch's AGPS requests. nil answers none.
    init(link: any GarminServiceLink, importer: FITImporter, capabilities: Set<GarminCapability>, phoneName: String,
         newSyncProtocol: Bool? = nil,
         weatherProvider: (@MainActor () async -> WeatherReport?)?,
         agps: AGPSCache? = nil,
         output: @escaping @MainActor (GFDISessionOutput) -> Void) {
        self.link = link
        self.importer = importer
        self.capabilities = capabilities
        self.phoneName = phoneName
        self.newSyncProtocol = newSyncProtocol
        self.weatherProvider = weatherProvider
        self.http = WatchHTTPService(agps: agps)
        self.output = output
    }

    /// The link dropped: fail any upload in flight and forget the sync.
    func disconnected() {
        finishUpload(.failure(GarminWatchError.notConnected))
        download = nil
        pending = []
        isSyncing = false
        transferTask?.cancel()
        transferTask = nil
        listing = false
        legacyFirst = false
        pendingItems = []
        currentItem = nil
        failSettings(GarminWatchError.notConnected)
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
        if watchCapabilities.contains(.realtimeSettings) { await initSettings() }
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

    func sendWorkout(_ plan: WorkoutPlan) async throws {
        try await transferFile(WorkoutFitEncoder.encode(plan), subType: 5)
    }

    /// Uploads a file of the given data type and sub type. FIT files are data type 128: workouts are 5, settings are 2,
    /// courses are 6. Connect IQ apps are data type 255, sub type 17.
    func transferFile(_ data: Data, subType: UInt8, dataType: UInt8 = 128,
                      onProgress: (@MainActor (Double) -> Void)? = nil) async throws {
        guard upload == nil else { throw GarminWatchError.busy }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            upload = Upload(id: id, data: data, continuation: continuation, onProgress: onProgress)
            Task {
                do {
                    try await self.transmit(GFDICreateFile(
                        fileSize: UInt32(data.count), dataType: dataType, subType: subType,
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
        syncedActivities = 0
        output(.progress(0, "Listing activities"))
        legacyFirst = usesNewSync
        download = Download(file: nil)
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
        SyncDiagnostics.log("legacy download size=\(status.maxFileSize) file=\(download?.file != nil)")
        if download?.file != nil { reportFileProgress(0, of: Int(status.maxFileSize)) }
        if status.maxFileSize == 0 { await completeDownload() }
    }

    private func receiveDownloadChunk(_ data: Data) async {
        guard download?.size != nil else { return }
        download?.data.append(data)
        if let current = download, current.file != nil { reportFileProgress(current.data.count, of: current.size) }
        if let finished = download, let size = finished.size, finished.data.count >= size {
            await completeDownload()
        }
    }

    private func completeDownload() async {
        guard let finished = download, let size = finished.size else { return }
        download = nil
        let bytes = Data(finished.data.prefix(size))
        if let file = finished.file {
            if await keep(key(file), bytes: bytes) {
                if file.subType == Self.activityFileType { syncedActivities += 1 }
                await archive(file)
            }
        } else {
            var files = Self.directoryEntries(bytes).filter { $0.isFIT }
            if legacyFirst {
                let bySubType = Dictionary(grouping: files, by: \.subType).mapValues(\.count)
                SyncDiagnostics.log("legacy directory: \(files.count) FIT files by type \(bySubType.sorted { $0.key < $1.key })")
                // Activities and the rest come through the new listing; this pass only adds health files.
                files = files.filter { Self.legacyHealthTypes.contains($0.subType) }
            }
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
            if await importer.isKnown(key(file)) {
                await archive(file)
                continue
            }
            download = Download(file: file)
            reportFileProgress(0, of: nil)
            output(.progress(Double(syncDone) / Double(max(syncTotal, 1)), "Downloading activity \(syncDone) of \(syncTotal)"))
            await send(GFDIDownloadRequest(fileIndex: file.index, dataOffset: 0, mode: .new, crcSeed: 0, dataSize: 0))
            return
        }
        if legacyFirst {
            legacyFirst = false
            listing = true
            await sendFileList()
            return
        }
        await finishSync()
    }

    /// Monitoring, sleep, metrics, HRV status and the other daily health files in Gadgetbridge's pull list.
    static let legacyHealthTypes: Set<UInt8> = [32, 44, 49, 68, 70, 71, 73, 77, 79, 82]

    /// Hands a downloaded file to the import stage. True once the file is in the inbox, which is when the watch may
    /// archive it. A file that could not be kept stays on the watch for the next sync.
    private func keep(_ key: String, bytes: Data) async -> Bool {
        do {
            try await importer.accept(bytes, fileKey: key)
            return true
        } catch {
            output(.event(.log("Could not keep FIT file \(key): \(error)")))
            return false
        }
    }

    private func finishSync() async {
        guard isSyncing else { return }
        isSyncing = false
        output(.fileProgress(nil))
        await send(GFDISystemEvent(.syncComplete))
        if syncedActivities > 0 { await notifySyncedActivities(syncedActivities) }
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

    // MARK: - New sync protocol (file access service)

    private var usesNewSync: Bool {
        newSyncProtocol ?? watchCapabilities.contains(.sync2)
    }

    /// Gadgetbridge's SYNCED flag: set on a file once it has been pulled, and listed files exclude it.
    private static let syncedFlag: UInt64 = 42405

    private static func syncedUUID() -> GDI_Proto_DataTypes_UUID {
        var uuid = GDI_Proto_DataTypes_UUID()
        uuid.mostSignificant = syncedFlag
        uuid.leastSignificant = syncedFlag
        return uuid
    }

    private static func fileAccess(_ service: GDI_Proto_FileAccess_Service) -> GarminVivomovehr_Smart {
        var smart = GarminVivomovehr_Smart()
        smart.fileAccessService = service
        return smart
    }

    private func receiveFileAccess(_ service: GDI_Proto_FileAccess_Service, requestID: UInt16) async {
        guard usesNewSync else { return }
        if service.hasItemListResponse { await receiveItemList(service.itemListResponse) }
        if service.hasPullItemResponse { await receivePullResponse(service.pullItemResponse) }
        if service.hasItemAddedNotification {
            isSyncing = true
            for item in service.itemAddedNotification.items { addItem(item) }
            await processNextItem()
        }
        if service.hasTransferStatusRequest {
            var response = GDI_Proto_FileAccess_TransferStatusResponse()
            response.nextTransferPriority = 1
            var reply = GDI_Proto_FileAccess_Service()
            reply.transferStatusResponse = response
            await sendProtobufResponse(Self.fileAccess(reply), requestID: requestID)
        }
        if service.hasSyncButtonNotification { await requestSync() }
    }

    /// Asks for one page of the file list. Without a session the list starts at the last page the watch named.
    private func sendFileList(sessionID: UInt32? = nil) async {
        let synced = Self.syncedUUID()
        var request = GDI_Proto_FileAccess_ItemListRequest()
        request.getFlags = [synced]
        if listingRecent {
            // Every health file regardless of its synced flag, with its modified time. The watch filters by type when
            // it can; otherwise the phone does (see addItem).
            if recentTypeFilter {
                request.includedDataTypes = Self.pulledTypes.sorted().map { name in
                    GDI_Proto_FileAccess_DataType.with { $0.format = .gdxmlDataType; $0.gdxmlString = name }
                }
            }
            request.requestedMetadata = [.modifiedTime]
        } else {
            request.excludeAllFlags = [synced]
        }
        if let sessionID {
            request.sessionID = sessionID
        } else if !listingRecent, let nextTransactionID {
            request.transactionID = nextTransactionID
        }
        var service = GDI_Proto_FileAccess_Service()
        service.itemListRequest = request
        SyncDiagnostics.log("list request session=\(sessionID.map(String.init) ?? "nil") transaction=\(request.hasTransactionID ? String(request.transactionID) : "nil")")
        try? await sendProtobufRequest(Self.fileAccess(service))
    }

    /// Queues the FIT files of a page. Other file types are not pulled, so they are never marked as synced.
    private func addItem(_ item: Item) {
        guard let name = typeName(of: item) else { return }
        guard Self.pulledTypes.contains(name) else { return }
        if listingRecent {
            guard !pendingItems.contains(where: { $0.uid == item.uid }) else { return }
            guard let modified = Self.modifiedDate(item), modified > .now.addingTimeInterval(-Self.recentWindow) else { return }
        }
        // As Gadgetbridge: the pulled item carries its resolved type name.
        var item = item
        item.dataType = GDI_Proto_FileAccess_DataType.with { $0.gdxmlString = name }
        pendingItems.append(item)
        syncTotal += 1
    }

    /// The item's type name. Only the first item of a type carries the name; the others carry just its key, which
    /// this resolves through the names seen so far on this connection (Gadgetbridge's nameMap).
    private func typeName(of item: Item) -> String? {
        guard item.hasDataType else { return nil }
        let type = item.dataType
        if type.hasGdxmlString, !type.gdxmlString.isEmpty {
            if type.hasGdxmlStringKey { typeNames[type.gdxmlStringKey] = type.gdxmlString }
            return type.gdxmlString
        }
        return type.hasGdxmlStringKey ? typeNames[type.gdxmlStringKey] : nil
    }

    private var typeNames: [UInt32: String] = [:]

    /// The item's modified time. The watch's unit is not documented: values past 2017 as Unix seconds are read as
    /// Unix time, smaller ones as Garmin-epoch seconds.
    private static func modifiedDate(_ item: Item) -> Date? {
        guard item.hasModifiedTime else { return nil }
        let value = item.modifiedTime
        return value > 1_500_000_000 ? Date(timeIntervalSince1970: TimeInterval(value)) : GarminTime.date(fromGarmin: value)
    }

    /// The FIT files Gadgetbridge pulls (FileType.FILETYPE with `pull`): activities, monitoring, sleep, metrics, HRV
    /// and the like. Device, settings, sport, workout and course files stay on the watch and are not marked synced.
    static let pulledTypes: Set<String> = Set([
        4, 9, 15, 28, 32, 35, 38, 41, 44, 49, 52, 57, 58, 61, 66, 68, 70, 71, 72, 73, 74, 77, 79, 82,
    ].map { "FIT_TYPE_\($0)" })

    private func receiveItemList(_ response: GDI_Proto_FileAccess_ItemListResponse) async {
        SyncDiagnostics.log("list status=\(response.status) items=\(response.items.count) session=\(response.hasSessionID ? String(response.sessionID) : "nil") next=\(response.hasNextTransactionID ? String(response.nextTransactionID) : "nil")")
        for item in response.items { addItem(item) }
        if !listingRecent, response.hasNextTransactionID { nextTransactionID = response.nextTransactionID }
        if listingRecent {
            recentPages += 1
            if response.status == .failInvalidDataType, recentTypeFilter {
                recentTypeFilter = false
                await sendFileList()
                return
            }
        }
        if response.hasSessionID, !(listingRecent && recentPages >= Self.maxRecentPages) {
            await sendFileList(sessionID: response.sessionID)
        } else if !recentPassDone {
            recentPassDone = true
            listingRecent = true
            await sendFileList()
        } else {
            listingRecent = false
            listing = false
            await processNextItem()
        }
    }

    /// Pulls the next file that is not imported yet. Imported files are only marked as synced on the watch.
    private func processNextItem() async {
        guard currentItem == nil else { return }
        while !pendingItems.isEmpty {
            let item = pendingItems.removeFirst()
            syncDone += 1
            if await importer.isKnown(itemKey(item)) {
                await markSynced(item)
                continue
            }
            currentItem = item
            SyncDiagnostics.log("pull \(syncDone)/\(syncTotal) \(item.dataType.gdxmlString) size=\(item.hasDataSize ? String(item.dataSize) : "nil")")
            reportFileProgress(0, of: item.hasDataSize ? Int(item.dataSize) : nil)
            output(.progress(Double(syncDone) / Double(max(syncTotal, 1)), "Downloading activity \(syncDone) of \(syncTotal)"))
            try? await sendProtobufRequest(Self.pullRequest(item))
            return
        }
        guard !listing else { return }
        await finishSync()
    }

    private func receivePullResponse(_ response: GDI_Proto_FileAccess_PullItemDataResponse) async {
        guard let item = currentItem else { return }
        guard response.result == .success else {
            currentItem = nil
            await processNextItem()
            return
        }
        let handle = response.transferHandle
        transferTask = Task { await self.fetchCurrent(item, handle: handle) }
    }

    /// Reads the pulled file from its transfer service, imports it, and marks it as synced on the watch.
    private func fetchCurrent(_ item: Item, handle: UInt32) async {
        let bytes = try? await transfer(handle: handle, size: item.hasDataSize ? Int(item.dataSize) : nil)
        guard !Task.isCancelled else { return }
        if let bytes, await keep(itemKey(item), bytes: bytes) {
            if item.dataType.gdxmlString == Self.activityItemType { syncedActivities += 1 }
            await markSynced(item)
        }
        currentItem = nil
        await processNextItem()
    }

    /// Opens a transfer service and asks for the file with the handle the watch gave it. The watch answers with a
    /// 0,0,0 marker and then the zlib-compressed file, and closes the service when it is done.
    private func transfer(handle: UInt32, size: Int?) async throws -> Data? {
        let channel = try await link.openFileTransfer()
        var request = ByteWriter()
        request.writeUInt8(0)
        request.writeUInt8(0)
        request.writeUInt16(UInt16(truncatingIfNeeded: handle))
        request.writeUInt8(0)
        request.writeUInt8(0)
        try await channel.send(request.data)

        var compressed = Data()
        var started = false
        var payloads = 0
        // Inflating as the data arrives only measures progress; the file itself is inflated in one go at the end.
        let meter = InflateMeter()
        for await payload in channel.incoming {
            guard started else {
                guard payload == Data([0, 0, 0]) else { return nil }
                started = true
                continue
            }
            compressed.append(payload)
            payloads += 1
            let inflated = meter.feed(payload)
            if let inflated { reportFileProgress(inflated, of: size) }
        }
        let file = Self.inflate(compressed)
        SyncDiagnostics.log("transfer done payloads=\(payloads) compressed=\(compressed.count) inflated=\(file?.count ?? -1) meter=\(meter.inflatedBytes) size=\(size.map(String.init) ?? "nil")")
        return file
    }

    /// Reports the current file's progress, at most once per percent so the UI is not flooded per BLE packet.
    private func reportFileProgress(_ bytes: Int, of total: Int?) {
        let progress = FileTransferProgress(bytes: bytes, totalBytes: total)
        let step = progress.fraction.map { Int($0 * 100) } ?? bytes / 4096
        guard step != lastFileProgressStep || bytes == 0 else { return }
        lastFileProgressStep = step
        output(.fileProgress(progress))
    }

    /// Garmin sends a zlib stream: a two-byte header, then deflate data. Foundation's `.zlib` takes the deflate data alone.
    private static func inflate(_ compressed: Data) -> Data? {
        guard compressed.count > 2 else { return nil }
        return try? (Data(compressed.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data
    }

    private func markSynced(_ item: Item) async {
        var modify = GDI_Proto_FileAccess_ModifyFlagsRequest()
        modify.uid = item.uid
        modify.setFlags = [Self.syncedUUID()]
        var service = GDI_Proto_FileAccess_Service()
        service.modifyFlagsRequest = modify
        try? await sendProtobufRequest(Self.fileAccess(service))
    }

    private static func pullRequest(_ item: Item) -> GarminVivomovehr_Smart {
        var pull = GDI_Proto_FileAccess_PullItemDataRequest()
        pull.item = item
        pull.priority = 24
        pull.supportedTransports = [.multilinkTransportPipe]
        pull.offset = 0
        pull.requestedCompressionWindow = 15
        var service = GDI_Proto_FileAccess_Service()
        service.pullItemRequest = pull
        return fileAccess(service)
    }

    private func itemKey(_ item: Item) -> String {
        "\(deviceInfo?.unitNumber ?? 0)-\(item.uid.mostSignificant)-\(item.uid.leastSignificant)"
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
        current.onProgress?(Double(current.offset) / Double(max(current.data.count, 1)))
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
        if smart.hasCalendarEventsService {
            await sendProtobufResponse(GFDICalendar.response(to: smart.calendarEventsService, events: calendarEvents),
                                       requestID: chunk.requestID)
        }
        if smart.hasDeviceStatusService, smart.deviceStatusService.hasRemoteDeviceBatteryStatusResponse {
            let status = smart.deviceStatusService.remoteDeviceBatteryStatusResponse
            let charging = status.batteryStatus == .charging || status.batteryStatus == .fullyCharged
            output(.event(.battery(BatteryStatus(percent: Int(status.currentBatteryLevel), isCharging: charging))))
        }
        if smart.hasFileAccessService {
            await receiveFileAccess(smart.fileAccessService, requestID: chunk.requestID)
        }
        if smart.hasRealtimeSettingsService {
            receiveRealtimeSettings(smart.realtimeSettingsService)
        }
        if smart.hasConnectIqInstalledAppsService {
            receiveInstalledApps(smart.connectIqInstalledAppsService)
        }
        if let reply = http.reply(to: smart) {
            await sendProtobufResponse(reply, requestID: chunk.requestID)
        }
    }

    func sendProtobufRequest(_ smart: GarminVivomovehr_Smart) async throws {
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

    func transmit(_ message: some GFDIOutgoing) async throws {
        try await link.send(message.frame().encoded())
    }

    /// A send that fails only when the link is gone, which the service sees as a drop, so the error is not kept.
    func send(_ message: some GFDIOutgoing) async {
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
