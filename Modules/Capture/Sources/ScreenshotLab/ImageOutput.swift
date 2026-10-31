import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageOutputError: LocalizedError {
    case encodeFailed
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "无法编码图片。"
        case .unsupportedFormat(let format):
            return "当前 macOS ImageIO 不支持写入 \(format) 格式。"
        }
    }
}

enum ImageOutput {
    static func write(_ image: CGImage, to url: URL) throws {
        let type: UTType
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            type = .jpeg
        case "webp":
            throw ImageOutputError.unsupportedFormat("WebP")
        default:
            type = .png
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageOutputError.encodeFailed
        }
        let properties: CFDictionary?
        if type == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        } else {
            properties = nil
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageOutputError.encodeFailed
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try write(image, to: url)
    }

    static func makeTemporaryPNG(_ image: CGImage) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotLab", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "Screenshot-\(UUID().uuidString).png"
        )
        try writePNG(image, to: url)
        return url
    }
}
