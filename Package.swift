// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Wheelie",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WheelieCore"),
        .executableTarget(name: "Wheelie", dependencies: ["WheelieCore"]),
        .testTarget(name: "WheelieCoreTests", dependencies: ["WheelieCore"]),
    ]
)
