// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PrivilegedSupport", platforms: [.macOS(.v14)],
    products: [.library(name: "PrivilegedSupport", targets: ["PrivilegedSupport"])],
    targets: [.target(name: "PrivilegedSupport", linkerSettings: [.linkedFramework("Security")]),
              .executableTarget(name: "PrivilegedSupportSmoke", dependencies: ["PrivilegedSupport"], path: "Tests/PrivilegedSupportTests")],
    swiftLanguageModes: [.v5])
