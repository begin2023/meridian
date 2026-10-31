// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Thermal", platforms: [.macOS(.v14)],
    products: [.library(name: "FanControlLabKit", targets: ["FanControlLabKit"]),
               .executable(name: "FanControlLabDaemon", targets: ["FanControlLabDaemon"])],
    targets: [
        .target(name: "FanControlLabKit", path: "Sources/FanControlLab", exclude: [
            "main.swift", "Core/FanWriteExperiment.swift", "SMC/HelperProtocol.swift"], linkerSettings: [
            .linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "FanControlLabDaemon", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "FanControlLabKitSmoke", dependencies: ["FanControlLabKit"])
    ], swiftLanguageModes: [.v5])
