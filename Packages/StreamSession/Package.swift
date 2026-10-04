// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StreamSession",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "StreamSession", targets: ["StreamSession"]),
    ],
    targets: [
        .target(name: "StreamSession"),
        .testTarget(name: "StreamSessionTests", dependencies: ["StreamSession"]),
    ]
)
