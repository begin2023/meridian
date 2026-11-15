// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Monitoring", platforms: [.macOS(.v14)],
    products: [.library(name: "MonitoringLabKit", targets: ["MonitoringLabKit"])],
    dependencies: [.package(path: "../Localization")],
    targets: [
        .target(name: "MonitoringLabKit", dependencies: [.product(name: "MeridianLocalization", package: "Localization")], path: "Sources/MonitoringLab", exclude: ["main.swift"],
                linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("DiskArbitration")]),
        .executableTarget(name: "MonitoringLabKitSmoke", dependencies: ["MonitoringLabKit"])
    ], swiftLanguageModes: [.v5])
