// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NowPlayingFeed",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "NowPlayingFeed", targets: ["NowPlayingFeed"]),
    ],
    targets: [
        .target(name: "NowPlayingFeed"),
        .testTarget(name: "NowPlayingFeedTests", dependencies: ["NowPlayingFeed"]),
    ]
)
