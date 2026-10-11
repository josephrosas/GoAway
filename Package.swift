// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoAway",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GoAway", targets: ["GoAway"]),
        .executable(name: "GoAwayCheck", targets: ["GoAwayCheck"])
    ],
    targets: [
        .target(
            name: "GoAwayCore",
            path: "Sources/GoAwayCore",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "GoAway",
            dependencies: ["GoAwayCore"],
            path: "Sources/GoAway",
            exclude: ["Assets"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("DiskArbitration")
            ]
        ),
        .executableTarget(
            name: "GoAwayCheck",
            dependencies: ["GoAwayCore"],
            path: "Sources/GoAwayCheck"
        ),
        .testTarget(
            name: "GoAwayTests",
            dependencies: ["GoAwayCore"],
            path: "Tests/GoAwayTests"
        )
    ]
)
