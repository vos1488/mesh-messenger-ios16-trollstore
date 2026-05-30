// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeshMessenger",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "MeshMessenger", targets: ["MeshMessenger"])
    ],
    targets: [
        .target(
            name: "MeshMessenger",
            path: "Sources"
        ),
        .testTarget(
            name: "MeshMessengerTests",
            dependencies: ["MeshMessenger"],
            path: "Tests"
        )
    ]
)

