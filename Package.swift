// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Cats",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Cats",
            targets: ["Cats"]
        ),
    ],
    targets: [
        .target(
            name: "Cats"
        ),
        .testTarget(
            name: "CatsTests",
            dependencies: ["Cats"]
        ),
    ]
)
