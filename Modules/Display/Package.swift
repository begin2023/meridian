// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Display", platforms: [.macOS(.v14)],
    products: [.library(name: "DisplayLabKit", targets: ["DisplayLabKit"]),
               .executable(name: "DisplayLabHelper", targets: ["DisplayLabHelper"])],
    dependencies: [.package(path: "../PrivilegedSupport")],
    targets: [
        .target(name: "BrightnessMapping", path: "Sources/BrightnessMapping"),
        .target(name: "DisplayPrivate", publicHeadersPath: "include"),
        .target(name: "DisplayCore", dependencies: ["DisplayPrivate"], linkerSettings: [
            .linkedFramework("IOKit"), .linkedFramework("CoreGraphics"), .linkedFramework("CoreDisplay")]),
        .target(name: "DisplayLabKit", dependencies: ["DisplayCore", "BrightnessMapping", .product(name: "PrivilegedSupport", package: "PrivilegedSupport")], path: "Sources/DisplayLab", linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("Carbon"), .linkedFramework("ServiceManagement"), .linkedFramework("Security")]),
        .executableTarget(name: "DisplayLabHelper", dependencies: ["DisplayCore", .product(name: "PrivilegedSupport", package: "PrivilegedSupport")], linkerSettings: [
            .linkedFramework("Foundation"), .linkedFramework("Security")]),
        .executableTarget(name: "DisplayLabKitSmoke", dependencies: ["DisplayLabKit"]),
        .executableTarget(name: "DisplayCoreSmoke", dependencies: ["DisplayCore"]),
        .executableTarget(name: "DisplayBrightnessMappingSmoke", dependencies: ["BrightnessMapping"])
    ], swiftLanguageModes: [.v5])
