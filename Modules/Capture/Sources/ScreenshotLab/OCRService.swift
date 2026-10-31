import CoreGraphics
import Foundation
import ImageIO
import Vision
import VisionKit

public struct RecognizedText: Sendable {
    public let content: String
    public let lineCount: Int
    public let characterCount: Int
    public let elapsedMilliseconds: Double
}

enum OCRError: LocalizedError {
    case noText
    case timedOut
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noText:
            return "没有在当前截图中识别到文字。"
        case .timedOut:
            return "文字识别超过 45 秒，请重试或裁剪为较小区域。"
        case .recognitionFailed(let message):
            return "文字识别失败：\(message)"
        }
    }
}

public enum OCRService {
    public static func recognize(image: CGImage, timeout: TimeInterval = 45) async throws -> RecognizedText {
        let started = DispatchTime.now().uptimeNanoseconds
        let boundedTimeout = timeout.isFinite ? min(45, max(0.001, timeout)) : 45
        let input = downsampleForRecognition(image)
        do {
            if let result = try await recognizeWithVisionKit(
                image: input,
                source: image,
                started: started,
                timeout: boundedTimeout
            ) {
                return result
            }
        } catch OCRError.timedOut {
            throw OCRError.timedOut
        } catch OCRError.noText {
            throw OCRError.noText
        } catch {
            // VisionKit is available on all supported systems, but retain the
            // Vision request path as a fallback for damaged assets or services.
        }

        let job = RecognitionJob(timeout: boundedTimeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(image: input, source: image, started: started, continuation: continuation)
            }
        } onCancel: { job.finish(.failure(CancellationError()), cancelRequest: true) }
    }

    private static func recognizeWithVisionKit(
        image: CGImage,
        source: CGImage,
        started: UInt64,
        timeout: TimeInterval
    ) async throws -> RecognizedText? {
        guard ImageAnalyzer.isSupported else { return nil }
        return try await withThrowingTaskGroup(of: RecognizedText?.self) { group in
            group.addTask {
                guard !Task.isCancelled else { throw CancellationError() }
                var configuration = ImageAnalyzer.Configuration(.text)
                configuration.locales = ["zh-Hans", "en-US"]
                let analysis = try await ImageAnalyzer().analyze(
                    image,
                    orientation: .up,
                    configuration: configuration
                )
                let content = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard analysis.hasResults(for: .text), !content.isEmpty else {
                    throw OCRError.noText
                }
                let lines = content.split(whereSeparator: \.isNewline)
                guard !lines.isEmpty else { throw OCRError.noText }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                NSLog("[OCR] VisionKit %dx%d (source %dx%d) in %.0f ms",
                      image.width, image.height, source.width, source.height, elapsed)
                return RecognizedText(
                    content: content,
                    lineCount: lines.count,
                    characterCount: content.count,
                    elapsedMilliseconds: elapsed
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw OCRError.timedOut
            }
            do {
                guard let result = try await group.next() else {
                    throw OCRError.noText
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private final class RecognitionJob: @unchecked Sendable {
        private let lock = NSLock()
        private let request = VNRecognizeTextRequest()
        private var continuation: CheckedContinuation<RecognizedText, Error>?
        private var result: Result<RecognizedText, Error>?
        private var deadline: DispatchWorkItem?
        private let timeout: TimeInterval

        init(timeout: TimeInterval) {
            self.timeout = timeout.isFinite ? min(45, max(0.001, timeout)) : 45
            OCRService.configure(request)
        }

        func start(
            image: CGImage,
            source: CGImage,
            started: UInt64,
            continuation: CheckedContinuation<RecognizedText, Error>
        ) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            self.continuation = continuation
            let deadline = DispatchWorkItem { [weak self] in
                self?.finish(.failure(OCRError.timedOut), cancelRequest: true)
            }
            self.deadline = deadline
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock(); let finished = result != nil; lock.unlock()
                guard !finished else { return }
                finish(Result {
                    try recognizeSynchronously(image: image, source: source, started: started)
                })
            }
        }

        func finish(_ value: Result<RecognizedText, Error>, cancelRequest: Bool = false) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let callback = continuation; continuation = nil
            let deadline = self.deadline; self.deadline = nil
            lock.unlock()
            deadline?.cancel()
            callback?.resume(with: value)
            if cancelRequest { request.cancel() }
        }

        private func recognizeSynchronously(
            image: CGImage,
            source: CGImage,
            started: UInt64
        ) throws -> RecognizedText {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw OCRError.recognitionFailed(error.localizedDescription)
            }

            guard let observations = request.results else {
                throw OCRError.noText
            }

            let lines = observations.compactMap { observation -> (CGRect, String)? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                return (observation.boundingBox, candidate.string)
            }
            .sorted { lhs, rhs in
                let leftMidY = lhs.0.midY
                let rightMidY = rhs.0.midY
                if abs(leftMidY - rightMidY) > 0.01 {
                    return leftMidY > rightMidY
                }
                return lhs.0.minX < rhs.0.minX
            }
            .map(\.1)

            guard !lines.isEmpty else {
                throw OCRError.noText
            }

            let content = lines.joined(separator: "\n")
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            NSLog("[OCR] accurate recognition %dx%d (source %dx%d) in %.0f ms",
                  image.width, image.height, source.width, source.height, elapsedMS)
            return RecognizedText(
                content: content,
                lineCount: lines.count,
                characterCount: content.count,
                elapsedMilliseconds: elapsedMS
            )
        }
    }

    private static func configure(_ request: VNRecognizeTextRequest) {
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Vision chooses the script per text region. For mixed Chinese/English
        // screenshots this is faster and more accurate than forcing one locale.
        request.automaticallyDetectsLanguage = true
    }

    static func downsampleForRecognition(_ image: CGImage) -> CGImage {
        // Bound VisionKit/Vision's peak allocation for 5K captures.
        let maxDimension = 3600
        let longest = max(image.width, image.height)
        guard longest > maxDimension else { return image }
        let factor = Double(maxDimension) / Double(longest)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
