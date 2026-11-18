// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenGarminServer",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.12.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.9.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.0.0"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(path: "../GarminKit"),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .executableTarget(
            name: "App",
            dependencies: [
                "CZlib",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "SotoS3", package: "soto"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GarminFIT", package: "GarminKit"),
                .product(name: "GarminModels", package: "GarminKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "GarminFIT", package: "GarminKit"),
                .product(name: "GarminModels", package: "GarminKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
