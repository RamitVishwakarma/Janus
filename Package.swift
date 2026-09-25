// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Switchboard", targets: ["Switchboard"]),
        .library(name: "SwitchboardCore", targets: ["SwitchboardCore"])
    ],
    targets: [
        .target(name: "SwitchboardCore"),
        .executableTarget(name: "Switchboard", dependencies: ["SwitchboardCore"]),
        .testTarget(name: "SwitchboardCoreTests", dependencies: ["SwitchboardCore"])
    ]
)
