import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct GIFCaptureRegion {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let selection: CGRect
}

enum GIFRecorderError: LocalizedError {
    case alreadyRecording
    case displayNotFound
    case streamSetupFailed(String)
    case frameConversionFailed
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "已经有一个 GIF 录制任务。"
        case .displayNotFound:
            return "无法找到 GIF 录制区域对应的显示器。"
        case .streamSetupFailed(let message):
            return "无法开始 GIF 录制：\(message)"
        case .frameConversionFailed:
            return "无法把屏幕帧转换成图片。"
        case .stopFailed(let message):
            return "停止 GIF 录制失败：\(message)"
        }
    }
}

final class GIFRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let framesPerSecond: Int
    let maximumDuration: TimeInterval = 30
    let maximumWidth: Int
    private let automaticSaveDirectory: URL

    var onProgress: ((TimeInterval, Int, Int) -> Void)?
    var onFinishing: ((Bool) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?

    private let sampleQueue = DispatchQueue(label: "app.meridian.screenshot.gif-capture")
    private let encodingQueue = DispatchQueue(label: "app.meridian.screenshot.gif-encoding")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var encoder: GIFEncoder?
    private var startTime: TimeInterval?
    private var receivedFrames = 0
    private var finishing = false
    private var completed = false
    /// ScreenCaptureKit only delivers frames when the screen changes. A timer
    /// re-emits the last frame so the GIF keeps its wall-clock duration at the
    /// configured frame rate instead of speeding up static recordings.
    private var frameTimer: DispatchSourceTimer?
    private var latestPixelBuffer: CVPixelBuffer?
    private var capturedFrameCount = 0
    private var copiedFrameGeneration = 0
    private var latestOwnedImage: CGImage?

    init(framesPerSecond: Int? = nil, maximumWidth: Int? = nil, automaticSaveDirectory: URL? = nil) {
        self.framesPerSecond = min(20, max(1, framesPerSecond ?? AppSettings.shared.gifFramesPerSecond))
        self.maximumWidth = min(1280, max(16, maximumWidth ?? AppSettings.shared.gifMaximumWidth))
        self.automaticSaveDirectory = automaticSaveDirectory ?? AppSettings.shared.quickSaveDirectory
        super.init()
    }

    var isRecording: Bool {
        withStateLock {
            stream != nil && !finishing
        }
    }

    func start(region: GIFCaptureRegion) async throws {
        let alreadyRunning = withStateLock { self.stream != nil }
        guard !alreadyRunning else {
            throw GIFRecorderError.alreadyRecording
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw GIFRecorderError.streamSetupFailed(error.localizedDescription)
        }

        guard let display = content.displays.first(where: {
            $0.displayID == region.displayID
        }) else {
            throw GIFRecorderError.displayNotFound
        }

        let ownApplication = content.applications.first {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter: SCContentFilter
        if let ownApplication {
            filter = SCContentFilter(
                display: display,
                excludingApplications: [ownApplication],
                exceptingWindows: []
            )
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let pointScale = max(1, CGFloat(filter.pointPixelScale))
        let sourceWidth = max(16, region.selection.width * pointScale)
        let sourceHeight = max(16, region.selection.height * pointScale)
        let outputWidth = min(CGFloat(maximumWidth), sourceWidth)
        let outputHeight = max(16, sourceHeight * outputWidth / sourceWidth)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: region.selection.minX,
            y: region.screenFrame.height - region.selection.maxY,
            width: region.selection.width,
            height: region.selection.height
        )
        configuration.width = Int(outputWidth.rounded())
        configuration.height = Int(outputHeight.rounded())
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(framesPerSecond)
        )
        configuration.queueDepth = 4
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.captureResolution = .best

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotLab-\(UUID().uuidString).gif")
        let encoder = try GIFEncoder(
            url: temporaryURL,
            framesPerSecond: Double(framesPerSecond)
        )
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )

        do {
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: sampleQueue
            )
            self.encoder = encoder
            withStateLock {
                self.stream = stream
                self.finishing = false
                self.latestPixelBuffer = nil
                self.capturedFrameCount = 0
            }
            self.receivedFrames = 0
            self.completed = false
            try await stream.startCapture()
            self.encodingQueue.async { [weak self] in
                self?.startTime = ProcessInfo.processInfo.systemUptime
                self?.startFrameTimer()
            }
        } catch {
            encoder.cancel()
            clearState()
            throw GIFRecorderError.streamSetupFailed(error.localizedDescription)
        }
    }

    func stop(saveTo directory: URL, save: Bool = true) {
        stop(saveTo: directory, save: save, error: nil)
    }

    private func stop(saveTo directory: URL, save: Bool, error: Error?) {
        let activeStream: SCStream? = withStateLock {
            if finishing || stream == nil {
                return nil
            }
            finishing = true
            return stream
        }
        guard let activeStream else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onFinishing?(save)
        }

        encodingQueue.async { [weak self] in
            self?.frameTimer?.cancel()
            self?.frameTimer = nil
        }

        Task {
            do {
                try await activeStream.stopCapture()
            } catch {
                self.encodingQueue.async {
                    self.frameTimer?.cancel()
                    self.frameTimer = nil
                    self.finish(
                        saveTo: directory,
                        save: false,
                        error: GIFRecorderError.stopFailed(
                            error.localizedDescription
                        )
                    )
                }
                return
            }
            self.encodingQueue.async {
                self.finish(saveTo: directory, save: save, error: error)
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        let shouldIgnore = withStateLock { finishing || self.stream !== stream }
        guard !shouldIgnore, outputType == .screen else {
            return
        }
        guard sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let rawFrameStatus = attachments.first?[.status] as? NSNumber,
              (rawFrameStatus.intValue == SCFrameStatus.complete.rawValue
                || rawFrameStatus.intValue == SCFrameStatus.started.rawValue) else {
            return
        }

        withStateLock {
            guard !finishing else { return }
            latestPixelBuffer = pixelBuffer
            capturedFrameCount += 1
        }
    }

    private func startFrameTimer() {
        guard frameTimer == nil, isRecording else {
            return
        }
        let interval = 1.0 / Double(framesPerSecond)
        let timer = DispatchSource.makeTimerSource(queue: encodingQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.repeatLastFrameIfNeeded()
        }
        frameTimer = timer
        timer.resume()
    }

    private func repeatLastFrameIfNeeded() {
        guard isRecording, !completed else {
            return
        }
        let (pixelBuffer, capturedFrames) = withStateLock {
            (latestPixelBuffer, capturedFrameCount)
        }
        guard let pixelBuffer, let encoder else {
            return
        }
        do {
            if capturedFrames != copiedFrameGeneration {
                latestOwnedImage = try Self.copyImage(from: pixelBuffer)
                copiedFrameGeneration = capturedFrames
            }
            guard let image = latestOwnedImage else { return }
            try encoder.addFrame(image)
            receivedFrames += 1
            reportProgressAndCheckDuration(capturedFrames: capturedFrames)
        } catch {
            stop(saveTo: FileManager.default.temporaryDirectory, save: false, error: error)
        }
    }

    private static func copyImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw GIFRecorderError.frameConversionFailed
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw GIFRecorderError.frameConversionFailed
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // ImageIO retains added CGImages until finalization. A surface-backed
        // image would pin all four ScreenCaptureKit buffers and stop capture.
        let pixels = Data(bytes: baseAddress, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()
                    ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                ),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw GIFRecorderError.frameConversionFailed
        }
        return image
    }

    private func reportProgressAndCheckDuration(capturedFrames: Int) {
        let elapsed = startTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let frames = receivedFrames
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(elapsed, frames, capturedFrames)
        }
        if elapsed >= maximumDuration
            || Double(frames) >= maximumDuration * Double(framesPerSecond) {
            DispatchQueue.main.async { [weak self] in
                self?.autoStopRequested()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let unexpected = withStateLock {
            guard self.stream === stream, !finishing else { return false }
            finishing = true
            return true
        }
        guard unexpected else { return }
        encodingQueue.async {
            self.finish(
                saveTo: FileManager.default.temporaryDirectory,
                save: false,
                error: error
            )
        }
    }

    private func autoStopRequested() {
        guard isRecording else {
            return
        }
        stop(
            saveTo: automaticSaveDirectory,
            save: true
        )
    }

    private func finish(
        saveTo directory: URL,
        save: Bool,
        error: Error?
    ) {
        guard !completed else {
            return
        }
        completed = true

        if let error {
            encoder?.cancel()
            clearState()
            DispatchQueue.main.async {
                self.onFinish?(.failure(error))
            }
            return
        }

        guard save else {
            encoder?.cancel()
            clearState()
            DispatchQueue.main.async {
                self.onFinish?(.failure(CancellationError()))
            }
            return
        }

        do {
            let temporaryURL = try encoder?.finalize()
            guard let temporaryURL else {
                throw GIFEncoderError.encodeFailed
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let finalURL = directory.appendingPathComponent(
                "Recording-\(formatter.string(from: Date())).gif"
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            clearState()
            DispatchQueue.main.async {
                self.onFinish?(.success(finalURL))
            }
        } catch {
            encoder?.cancel()
            clearState()
            DispatchQueue.main.async {
                self.onFinish?(.failure(error))
            }
        }
    }

    private func clearState() {
        frameTimer?.cancel()
        frameTimer = nil
        latestOwnedImage = nil
        copiedFrameGeneration = 0
        withStateLock {
            latestPixelBuffer = nil
            stream = nil
            encoder = nil
            startTime = nil
            finishing = true
        }
    }

    private func withStateLock<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}
