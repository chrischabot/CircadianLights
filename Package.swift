// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CircadianLights",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/ceeK/Solar.git", from: "3.0.0"),
        .package(url: "https://github.com/open-meteo/sdk.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "CircadianLights",
            dependencies: [
                "Solar",
                .product(name: "OpenMeteoSdk", package: "sdk")
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
