// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Meridian",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: "Modules/Capture"),
        .package(path: "Modules/Scrolling"),
        .package(path: "Modules/Monitoring"),
        .package(path: "Modules/Display"),
        .package(path: "Modules/Thermal"),
    ],
    targets: [
        .executableTarget(
            name: "Meridian",
            dependencies: [
                .product(name: "ScreenshotLabKit", package: "Capture"),
                .product(name: "ScrollLabKit", package: "Scrolling"),
                .product(name: "MonitoringLabKit", package: "Monitoring"),
                .product(name: "DisplayLabKit", package: "Display"),
                .product(name: "FanControlLabKit", package: "Thermal"),
            ],
            path: "Sources/Meridian",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
