// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Monitoring", platforms: [.macOS(.v14)],
    products: [.library(name: "MonitoringLabKit", targets: ["MonitoringLabKit"])],
    targets: [
        .target(name: "MonitoringLabKit", path: "Sources/MonitoringLab", exclude: ["main.swift"],
                linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("DiskArbitration")]),
        .executableTarget(name: "MonitoringLabKitSmoke", dependencies: ["MonitoringLabKit"])
    ], swiftLanguageModes: [.v5])
