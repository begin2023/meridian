// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Localization", platforms: [.macOS(.v14)],
    products: [.library(name: "MeridianLocalization", targets: ["MeridianLocalization"])],
    targets: [.target(name: "MeridianLocalization")],
    swiftLanguageModes: [.v5])
