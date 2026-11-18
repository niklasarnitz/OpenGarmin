import Testing
@testable import GarminDevices

@Test func venu4MatchesBothBluetoothNameFormats() {
    #expect(GarminDeviceCatalog.match(bluetoothName: "Venu 4 - 45mm")?.id == "garmin_venu_4")
    #expect(GarminDeviceCatalog.match(bluetoothName: "Venu 4 41mm")?.id == "garmin_venu_4")
}

@Test func venu4NeedsItsSizeSuffix() {
    // The coordinator's pattern requires "mm", so a bare name must not match the Venu 4.
    #expect(GarminDeviceCatalog.match(bluetoothName: "Venu 4") == nil)
}

@Test func venuNamesWithSuffixesResolveToTheRightModel() {
    #expect(GarminDeviceCatalog.match(bluetoothName: "Venu 3")?.id == "garmin_venu_3")
    #expect(GarminDeviceCatalog.match(bluetoothName: "Venu 3S")?.id == "garmin_venu_3s")
}

@Test func forerunnerMatchesExactName() {
    #expect(GarminDeviceCatalog.match(bluetoothName: "Forerunner 955")?.id == "garmin_forerunner_955")
    #expect(GarminDeviceCatalog.match(bluetoothName: "Forerunner 955 LTE") == nil)
}

@Test func instinctMatchesAndIsMarkedExperimental() throws {
    let model = try #require(GarminDeviceCatalog.match(bluetoothName: "Instinct 2X"))
    #expect(model.id == "garmin_instinct_2x")
    #expect(model.displayName == "Garmin Instinct 2X")
    #expect(model.family == .watch)
    #expect(model.isExperimental)
}

@Test func unicodeNameMatches() {
    #expect(GarminDeviceCatalog.match(bluetoothName: "vívomove HR")?.id == "garmin_vivomove_hr")
}

@Test func nonGarminNameMatchesNothing() {
    #expect(GarminDeviceCatalog.match(bluetoothName: "Polar H10") == nil)
    #expect(GarminDeviceCatalog.match(bluetoothName: "") == nil)
}

@Test func inheritedFeaturesAndOwnOverridesResolve() throws {
    let venu4 = try #require(GarminDeviceCatalog.match(bluetoothName: "Venu 4 41mm"))
    // Heart rate and SpO2 come from the watch base class; the Venu 4 coordinator overrides only the sync protocol.
    #expect(venu4.features.contains(.heartRate))
    #expect(venu4.features.contains(.spo2))
    #expect(venu4.usesNewSyncProtocol)
    #expect(!venu4.isExperimental)
    #expect(venu4.gadgetbridgeCoordinator == "GarminVenu4Coordinator")
}

@Test func productNumberLookupFindsModel() throws {
    #expect(GarminDeviceCatalog.model(productNumber: 4643)?.id == "garmin_venu_4")
    #expect(GarminDeviceCatalog.model(productNumber: 4024)?.id == "garmin_forerunner_955")
    #expect(GarminDeviceCatalog.model(productNumber: 0) == nil)
}

@Test func everyModelHasUniqueIdAndCompilingPattern() {
    let ids = GarminDeviceCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(GarminDeviceCatalog.all.allSatisfy { (try? Regex($0.bluetoothNamePattern)) != nil })
}
