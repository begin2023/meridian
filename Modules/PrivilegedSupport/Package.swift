// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PrivilegedSupport", platforms: [.macOS(.v14)],
    products: [.library(name: "PrivilegedSupport", targets: ["PrivilegedSupport"])],
    dependencies: [.package(path: "../Localization")],
    targets: [.target(name: "PrivilegedSupport", dependencies: [.product(name: "MeridianLocalization", package: "Localization")], linkerSettings: [.linkedFramework("Security")]),
              .executableTarget(name: "PrivilegedSupportSmoke", dependencies: ["PrivilegedSupport"], path: "Tests/PrivilegedSupportTests")],
    swiftLanguageModes: [.v5])
