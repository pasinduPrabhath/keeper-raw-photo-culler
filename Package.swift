// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Keeper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Keeper", targets: ["Keeper"]),
        .library(name: "KeeperCore", targets: ["KeeperCore"]),
    ],
    targets: [
        // Pure logic: RAW preview extraction, burst grouping, sharpness, Google Drive.
        .target(name: "KeeperCore"),
        // The SwiftUI app.
        .executableTarget(name: "Keeper", dependencies: ["KeeperCore"]),
        // Generates a fake wildlife shoot (synthetic ARW files) for demos and tests.
        .executableTarget(name: "KeeperDemoGen", dependencies: ["KeeperCore"]),
        .testTarget(name: "KeeperCoreTests", dependencies: ["KeeperCore"]),
    ]
)
