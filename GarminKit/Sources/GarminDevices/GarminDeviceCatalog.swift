/// Every Garmin device Gadgetbridge supports. The data lives in `DeviceCatalog.generated.swift`.
public enum GarminDeviceCatalog {
    public static var all: [GarminDeviceModel] { models }

    /// The model whose Bluetooth name pattern matches the whole advertised name, like Gadgetbridge's `matcher().matches()`.
    /// Regex is not Sendable, so patterns compile per call; a scan over all models is cheap enough for discovery.
    public static func match(bluetoothName: String) -> GarminDeviceModel? {
        models.first { model in
            guard let regex = try? Regex(model.bluetoothNamePattern) else { return false }
            return bluetoothName.wholeMatch(of: regex) != nil
        }
    }

    /// The model that owns a FIT product number, like Gadgetbridge's `GarminProductNumbers.getDeviceType`.
    public static func model(productNumber: Int) -> GarminDeviceModel? {
        models.first { $0.productNumbers.contains(productNumber) }
    }
}
