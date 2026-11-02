// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoAway",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GoAway", targets: ["GoAway"]),
        .executable(name: "GoAwayProbe", targets: ["GoAwayProbe"]),
        .executable(name: "GoAwayCheck", targets: ["GoAwayCheck"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
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
            dependencies: [
                "GoAwayCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/GoAway",
            exclude: ["Assets"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("DiskArbitration")
            ]
        ),
        .executableTarget(
            name: "GoAwayProbe",
            dependencies: ["GoAwayCore"],
            path: "Sources/GoAwayProbe"
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
