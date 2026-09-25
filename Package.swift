// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Janus",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Janus", targets: ["Janus"]),
        .library(name: "JanusCore", targets: ["JanusCore"])
    ],
    targets: [
        .target(name: "JanusCore"),
        .executableTarget(name: "Janus", dependencies: ["JanusCore"]),
        .testTarget(name: "JanusCoreTests", dependencies: ["JanusCore"])
    ]
)
