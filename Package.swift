// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Relay", path: "Sources/Relay")
    ]
)
