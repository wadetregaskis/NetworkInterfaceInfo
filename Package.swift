// swift-tools-version: 5.9

import PackageDescription

let swiftSettings: [SwiftSetting] = [
   .enableUpcomingFeature("BareSlashRegexLiterals"),
   .enableUpcomingFeature("ConciseMagicFile"),
   .enableUpcomingFeature("ExistentialAny"),
   .enableUpcomingFeature("ForwardTrailingClosures"),
   .enableUpcomingFeature("ImplicitOpenExistentials"),
   .enableUpcomingFeature("StrictConcurrency"),
   // Sadly StrictConcurrency isn't actually recognised by the Swift compiler as an upcoming feature, due to an apparent oversight by the compiler team.  So "unsafe" flags have to be used.  But if you do use them, you can't then actually _use_ the package from any other package - the Swift Package Manager will throw up all over the idea with compiler errors.  Sigh.
   //.unsafeFlags(["-Xfrontend", "-strict-concurrency=complete", "-enable-actor-data-race-checks"]),
]

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
        .library(
            name: "NetworkInterfaceChangeMonitoring",
            targets: ["NetworkInterfaceChangeMonitoring"]),
    ],
    dependencies: [
        .package(url: "https://github.com/wadetregaskis/FoundationExtensions.git", .upToNextMajor(from: "3.0.0")),
    ],
    targets: [
        .target(
            name: "NetworkInterfaceInfo",
            dependencies: [.product(name: "FoundationExtensions", package: "FoundationExtensions")],
            swiftSettings: swiftSettings),
        .testTarget(
            name: "NetworkInterfaceInfoTests",
            dependencies: ["NetworkInterfaceInfo"],
            swiftSettings: swiftSettings),

        .target(
            name: "NetworkInterfaceChangeMonitoring",
            dependencies: ["NetworkInterfaceInfo",
                           .product(name: "FoundationExtensions", package: "FoundationExtensions")],
            swiftSettings: swiftSettings),
        .testTarget(
            name: "NetworkInterfaceChangeMonitoringTests",
            dependencies: ["NetworkInterfaceChangeMonitoring"],
            swiftSettings: swiftSettings)
    ]
)
