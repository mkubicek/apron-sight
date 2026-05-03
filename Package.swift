// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "apron-sight",
    products: [
        .library(name: "ApronSightCore", targets: ["ApronSightCore"])
    ],
    targets: [
        .target(name: "ApronSightCore"),
        .testTarget(
            name: "ApronSightCoreTests",
            dependencies: ["ApronSightCore"]
        )
    ]
)
