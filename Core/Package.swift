// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConstellationCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ConstellationCore", targets: ["ConstellationCore"]),
        .library(name: "ConstellationModels", targets: ["ConstellationModels"]),
        .library(name: "ConstellationLogging", targets: ["ConstellationLogging"]),
        .library(name: "ConstellationStorage", targets: ["ConstellationStorage"]),
        .executable(name: "constellation", targets: ["constellation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "ConstellationModels"),
        .target(name: "ConstellationLogging"),
        .target(
            name: "ConstellationStorage",
            dependencies: [
                "ConstellationModels",
                "ConstellationLogging",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "ConstellationCore",
            dependencies: [
                "ConstellationModels",
                "ConstellationLogging",
                "ConstellationStorage",
            ]
        ),
        .executableTarget(
            name: "constellation",
            dependencies: [
                "ConstellationCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "ConstellationModelsTests", dependencies: ["ConstellationModels"]),
        .testTarget(name: "ConstellationLoggingTests", dependencies: ["ConstellationLogging"]),
        .testTarget(name: "ConstellationStorageTests", dependencies: ["ConstellationStorage"]),
        .testTarget(name: "ConstellationCoreTests", dependencies: ["ConstellationCore"]),
    ],
    swiftLanguageModes: [.v6]
)
