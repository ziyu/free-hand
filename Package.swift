// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FreeHand",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FreeHand", path: "Sources/FreeHand"),
        .executableTarget(name: "FreeHandPlayground", path: "examples/Playground"),
        .testTarget(name: "FreeHandTests", dependencies: ["FreeHand"])
    ]
)
