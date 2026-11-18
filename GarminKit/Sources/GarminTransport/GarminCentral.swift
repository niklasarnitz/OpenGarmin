import CoreBluetooth
import Foundation

/// Garmin's 128-bit UUIDs share one base: 6A4E<short>-667B-11E3-949A-0800200C9A66.
func garminUUID(_ short: Int) -> CBUUID {
    CBUUID(string: "6A4E\(String(short, radix: 16, uppercase: true))-667B-11E3-949A-0800200C9A66")
}

/// The app's single CBCentralManager, shared by the scanner and every link. One owner keeps state restoration simple.
@MainActor
final class GarminCentral: NSObject {
    static let shared = GarminCentral()

    static let restoreIdentifier = "com.niklasarnitz.opengarmin.central"
    static let v2Service = garminUUID(0x2800)
    static let v1Service = garminUUID(0x2401)
    static let v0Service = CBUUID(string: "9B012401-BC30-CE9A-E111-0F67E491ABDE")
    static let serviceUUIDs = [v2Service, v1Service, v0Service]

    private(set) lazy var manager = CBCentralManager(
        delegate: self,
        queue: .main,
        options: [CBCentralManagerOptionRestoreIdentifierKey: GarminCentral.restoreIdentifier]
    )

    /// Links by peripheral identifier, so connection callbacks reach the right link.
    var links: [UUID: BLEGarminLink] = [:]
    var onDiscover: ((CBPeripheral, [String: Any], NSNumber) -> Void)?
    private(set) var restoredPeripheralIDs: [UUID] = []
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        super.init()
    }

    /// Returns once Core Bluetooth has reported a state (it starts as `.unknown`).
    func ready() async {
        guard manager.state == .unknown else { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    func peripheral(for id: UUID) -> CBPeripheral? {
        manager.retrievePeripherals(withIdentifiers: [id]).first
    }
}

extension GarminCentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown else { return }
        readyWaiters.forEach { $0.resume() }
        readyWaiters.removeAll()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restoredPeripheralIDs = peripherals.map(\.identifier)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        onDiscover?(peripheral, advertisementData, RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        links[peripheral.identifier]?.didConnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.didFail(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.didDisconnect(error)
    }
}
