// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Capture", platforms: [.macOS(.v14)],
    products: [.library(name: "ScreenshotLabKit", targets: ["ScreenshotLabKit"])],
    targets: [
        .target(name: "ScreenshotLabKit", path: "Sources/ScreenshotLab", linkerSettings: [
            .linkedFramework("Carbon"), .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("ServiceManagement"), .linkedFramework("Vision"),
            .linkedFramework("VisionKit"), .linkedFramework("ImageIO")]),
        .executableTarget(name: "ScreenshotLabKitSmoke", dependencies: ["ScreenshotLabKit"]),
        .executableTarget(name: "ScreenshotLabOCRSmoke", dependencies: ["ScreenshotLabKit"])
    ], swiftLanguageModes: [.v5])
