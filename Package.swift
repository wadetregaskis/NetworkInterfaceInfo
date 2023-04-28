// swift-tools-version: 5.5

import PackageDescription

let package = Package(
    name: "NetworkInterfaceInfo",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .macCatalyst(.v15),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "NetworkInterfaceInfo",
            targets: ["NetworkInterfaceInfo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/wadetregaskis/FoundationExtensions.git", .upToNextMajor(from: "2.0.0")),
    ],
    targets: [
        .target(
            name: "NetworkInterfaceInfo",
            dependencies: [.product(name: "FoundationExtensions", package: "FoundationExtensions")]),
        .testTarget(
            name: "NetworkInterfaceInfoTests",
            dependencies: ["NetworkInterfaceInfo"]),
    ]
)
