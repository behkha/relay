// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v13)],
    dependencies: [
        // nimbi's shared cloud, tokens and components. To work on both at once, swap in
        // .package(path: "../nimbi-kit") with a checkout next to this repo.
        .package(url: "https://github.com/behkha/nimbi-kit.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: [.product(name: "NimbiKit", package: "nimbi-kit")],
            path: "Sources/Relay"
        )
    ]
)
