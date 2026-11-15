// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Scrolling", platforms: [.macOS(.v14)],
    products: [.library(name: "ScrollLabKit", targets: ["ScrollLabKit"])],
    dependencies: [.package(path: "../Localization")],
    targets: [
        .target(name: "ScrollLabKit", dependencies: [.product(name: "MeridianLocalization", package: "Localization")], path: "Sources/ScrollLab", linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "ScrollLabKitSmoke", dependencies: ["ScrollLabKit"])
    ], swiftLanguageModes: [.v5])
