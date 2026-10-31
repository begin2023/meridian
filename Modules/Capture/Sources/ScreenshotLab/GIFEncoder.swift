import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GIFEncoderError: LocalizedError {
    case destinationCreationFailed
    case encodeFailed
    case noFrames

    var errorDescription: String? {
        switch self {
        case .destinationCreationFailed:
            return "无法创建 GIF 文件。"
        case .encodeFailed:
            return "GIF 编码失败。"
        case .noFrames:
            return "没有捕获到可写入 GIF 的帧。"
        }
    }
}

final class GIFEncoder {
    private let url: URL
    private let framesPerSecond: Double
    private var destination: CGImageDestination?

    private(set) var frameCount = 0

    init(url: URL, framesPerSecond: Double) throws {
        guard framesPerSecond > 0,
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.gif.identifier as CFString,
                  0,
                  nil
              ) else {
            throw GIFEncoderError.destinationCreationFailed
        }

        self.url = url
        self.framesPerSecond = framesPerSecond
        self.destination = destination

        let properties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, properties)
    }

    func addFrame(_ image: CGImage) throws {
        guard let destination else {
            throw GIFEncoderError.encodeFailed
        }
        // GIF delays use whole centiseconds. Distribute rounding across the
        // timeline (for example 7/6/7 cs at 15 fps) instead of drifting per frame.
        let previousEnd = (Double(frameCount) * 100 / framesPerSecond).rounded()
        let nextEnd = (Double(frameCount + 1) * 100 / framesPerSecond).rounded()
        let frameDelay = max(1, nextEnd - previousEnd) / 100
        let properties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
            ],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        frameCount += 1
    }

    func finalize() throws -> URL {
        guard frameCount > 0 else {
            throw GIFEncoderError.noFrames
        }
        guard let destination else {
            throw GIFEncoderError.encodeFailed
        }
        guard CGImageDestinationFinalize(destination) else {
            throw GIFEncoderError.encodeFailed
        }
        self.destination = nil
        return url
    }

    func cancel() {
        destination = nil
        try? FileManager.default.removeItem(at: url)
    }
}
