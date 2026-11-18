// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GarminKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "GarminKit", targets: [
            "GarminCore", "GarminModels", "GarminProtobuf", "GarminProtocol", "GarminFIT",
            "GarminTransport", "GarminDevices", "GarminSession", "GarminHealth",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        // Byte reading/writing, COBS, CRC. No dependencies.
        .target(name: "GarminCore"),
        // Plain value types shared by every layer (health samples, activities, device info, workouts).
        .target(name: "GarminModels"),
        // Swift code generated from Gadgetbridge's garmin/*.proto files.
        .target(name: "GarminProtobuf", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        // GFDI message framing and all typed GFDI messages.
        .target(name: "GarminProtocol", dependencies: ["GarminCore", "GarminModels"]),
        // FIT decoding/encoding and FIT -> GarminModels extraction.
        .target(name: "GarminFIT", dependencies: ["GarminCore", "GarminModels"]),
        // CoreBluetooth scanning, connection, V1 + V2 (MLR) link layer.
        .target(name: "GarminTransport", dependencies: ["GarminCore"]),
        // Catalog of supported Garmin devices (generated from Gadgetbridge coordinators).
        .target(name: "GarminDevices", dependencies: ["GarminModels"]),
        // The device session: handshake, sync, file transfer, notifications, weather, settings.
        .target(name: "GarminSession", dependencies: [
            "GarminCore", "GarminModels", "GarminProtobuf", "GarminProtocol", "GarminFIT", "GarminTransport", "GarminDevices",
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        ]),
        // HealthKit writing of GarminModels.
        .target(name: "GarminHealth", dependencies: ["GarminModels"]),

        .testTarget(name: "GarminCoreTests", dependencies: ["GarminCore"]),
        .testTarget(name: "GarminModelsTests", dependencies: ["GarminModels"]),
        .testTarget(name: "GarminProtocolTests", dependencies: ["GarminProtocol"]),
        .testTarget(name: "GarminFITTests", dependencies: ["GarminFIT"], resources: [.copy("Fixtures")]),
        .testTarget(name: "GarminTransportTests", dependencies: ["GarminTransport"]),
        .testTarget(name: "GarminDevicesTests", dependencies: ["GarminDevices"]),
        .testTarget(name: "GarminHealthTests", dependencies: ["GarminHealth", "GarminModels"]),
        .testTarget(name: "GarminSessionTests", dependencies: [
            "GarminSession", "GarminCore", "GarminFIT", "GarminModels", "GarminProtocol", "GarminTransport",
        ]),
    ]
)
