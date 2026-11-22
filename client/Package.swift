// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LCPClient",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LCPClient", targets: ["LCPClient"])],
    targets: [
        .target(name: "LCPClient", path: "Sources"),
        .testTarget(name: "LCPClientTests", dependencies: ["LCPClient"], path: "Tests/Unit"),
    ]
)
