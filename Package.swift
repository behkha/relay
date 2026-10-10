// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v13)],
    dependencies: [
        // nimbi's shared cloud, tokens and components, checked out next to this repo.
        .package(path: "../nimbi-kit")
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: [.product(name: "NimbiKit", package: "nimbi-kit")],
            path: "Sources/Relay"
        )
    ]
)
