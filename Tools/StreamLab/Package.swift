// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StreamLab",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "StreamDiagnostics", targets: ["StreamDiagnostics"]),
        .executable(name: "stream-lab", targets: ["StreamLab"]),
    ],
    dependencies: [
        .package(path: "../../Packages/StreamSession"),
    ],
    targets: [
        .target(name: "StreamDiagnostics"),
        .executableTarget(name: "StreamLab", dependencies: [
            "StreamDiagnostics",
            .product(name: "StreamSession", package: "StreamSession"),
        ]),
        .testTarget(name: "StreamDiagnosticsTests", dependencies: ["StreamDiagnostics"]),
        .testTarget(name: "StreamLabTests", dependencies: [
            "StreamLab",
            .product(name: "StreamSession", package: "StreamSession"),
        ]),
    ]
)
