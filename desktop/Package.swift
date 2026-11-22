// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LCPDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LCPContextCore", targets: ["LCPContextCore"]),
        .library(name: "LCPContextServices", targets: ["LCPContextServices"]),
        .executable(name: "LCPDesktop", targets: ["LCPDesktop"]),
        .executable(name: "LCPAgentBridge", targets: ["LCPAgentBridge"]),
    ],
    dependencies: [.package(path: "../client")],
    targets: [
        .target(name: "LCPContextCore"),
        .target(name: "LCPContextServices", dependencies: ["LCPContextCore"]),
        .executableTarget(name: "LCPDesktop", dependencies: ["LCPContextCore", "LCPContextServices", .product(name: "LCPClient", package: "client")]),
        .executableTarget(name: "LCPAgentBridge", dependencies: ["LCPContextCore", "LCPContextServices"]),
        .testTarget(name: "LCPContextCoreTests", dependencies: ["LCPContextCore"]),
        .testTarget(name: "LCPContextServicesTests", dependencies: ["LCPContextCore", "LCPContextServices"]),
        .testTarget(name: "LCPAgentBridgeTests", dependencies: ["LCPContextCore", "LCPContextServices", "LCPAgentBridge"]),
    ]
)
