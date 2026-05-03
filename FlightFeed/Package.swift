// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlightFeed",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "FlightFeed", targets: ["FlightFeed"]),
        .executable(name: "flightfeed-demo", targets: ["FlightFeedDemo"])
    ],
    targets: [
        .target(name: "FlightFeed"),
        .executableTarget(
            name: "FlightFeedDemo",
            dependencies: ["FlightFeed"]
        ),
        .testTarget(
            name: "FlightFeedTests",
            dependencies: ["FlightFeed"]
        )
    ]
)
