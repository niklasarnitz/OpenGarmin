import CoreBluetooth
import Foundation

/// Finds Garmin watches. Advertising watches come from a scan; bonded watches that stopped advertising come from
/// the system's connected list and from the restored peripherals of a background relaunch.
@MainActor
public final class GarminScanner {
    public nonisolated let watches: AsyncStream<[DiscoveredWatch]>
    private let sink: AsyncStream<[DiscoveredWatch]>.Continuation
    private var found: [UUID: DiscoveredWatch] = [:]

    /// Name fragments of Garmin wearables, from garmin-ble and Gadgetbridge.
    private static let nameHints = [
        "garmin", "fenix", "forerunner", "venu", "vivo", "instinct", "epix", "enduro", "tactix", "quatix", "marq",
        "descent", "approach", "lily",
    ]

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [DiscoveredWatch].self, bufferingPolicy: .bufferingNewest(1)
        )
        watches = stream
        sink = continuation
    }

    /// Starts scanning. Publishes the watches found so far on `watches` as they appear.
    public func start() async {
        await GarminCentral.shared.ready()
        let central = GarminCentral.shared
        central.onDiscover = { [weak self] peripheral, advertisement, rssi in
            let name = advertisement[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
            guard GarminScanner.isGarmin(name: name, advertisement: advertisement) else { return }
            self?.add(peripheral, name: name, rssi: rssi.intValue)
        }
        for peripheral in central.manager.retrieveConnectedPeripherals(withServices: GarminCentral.serviceUUIDs) {
            add(peripheral, name: peripheral.name, rssi: 0)
        }
        for id in central.restoredPeripheralIDs {
            if let peripheral = central.peripheral(for: id) { add(peripheral, name: peripheral.name, rssi: 0) }
        }
        central.manager.scanForPeripherals(withServices: nil)
    }

    public func stop() {
        GarminCentral.shared.manager.stopScan()
        GarminCentral.shared.onDiscover = nil
    }

    private static func isGarmin(name: String?, advertisement: [String: Any]) -> Bool {
        let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if services.contains(where: { GarminCentral.serviceUUIDs.contains($0) }) { return true }
        guard let name = name?.lowercased() else { return false }
        return nameHints.contains { name.contains($0) }
    }

    private func add(_ peripheral: CBPeripheral, name: String?, rssi: Int) {
        found[peripheral.identifier] = DiscoveredWatch(
            id: peripheral.identifier, name: name ?? "Garmin watch", rssi: rssi
        )
        sink.yield(found.values.sorted { $0.rssi > $1.rssi })
    }
}
