// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Thermal", platforms: [.macOS(.v14)],
    products: [.library(name: "FanControlLabKit", targets: ["FanControlLabKit"]),
               .executable(name: "FanControlLabDaemon", targets: ["FanControlLabDaemon"])],
    dependencies: [.package(path: "../PrivilegedSupport"), .package(path: "../Localization")],
    targets: [
        .target(name: "FanControlLabKit", dependencies: [.product(name: "MeridianLocalization", package: "Localization"), .product(name: "PrivilegedSupport", package: "PrivilegedSupport"), "FanControlProtocol"], path: "Sources/FanControlLab", exclude: [
            "main.swift"], linkerSettings: [
            .linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]),
        .target(name: "FanControlProtocol"),
        .executableTarget(name: "FanControlProtocolSmoke", dependencies: ["FanControlProtocol"]),
        .executableTarget(name: "FanControlLabDaemon", dependencies: [.product(name: "PrivilegedSupport", package: "PrivilegedSupport"), "FanControlProtocol"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "FanControlLabKitSmoke", dependencies: ["FanControlLabKit", .product(name: "MeridianLocalization", package: "Localization")])
    ], swiftLanguageModes: [.v5])
