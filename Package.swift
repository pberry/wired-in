// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiredIn",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WiredInKit", targets: ["WiredInKit"]),
        .executable(name: "WiredIn", targets: ["WiredIn"]),
        .executable(name: "wired", targets: ["wired"]),
    ],
    targets: [
        .target(name: "WiredInKit"),
        .executableTarget(name: "WiredIn", dependencies: ["WiredInKit"]),
        .executableTarget(name: "wired", dependencies: ["WiredInKit"]),
        .testTarget(name: "WiredInKitTests", dependencies: ["WiredInKit"]),
    ]
)
