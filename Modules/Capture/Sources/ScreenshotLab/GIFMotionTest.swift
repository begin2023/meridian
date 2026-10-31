import AppKit
import CryptoKit
import ImageIO

// An external video player supplies motion because the recorder excludes this
// application's own windows. Inspect the entire timeline, including its tail.
enum GIFMotionTest {
    private struct Fixture: Decodable {
        let displayID: UInt32
        let screenFrame: Rect
        let windowFrame: Rect
    }

    private struct Rect: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    @MainActor
    static func run() {
        func argument(_ name: String, fallback: String = "") -> String {
            guard let index = CommandLine.arguments.firstIndex(of: name),
                  index + 1 < CommandLine.arguments.count else { return fallback }
            return CommandLine.arguments[index + 1]
        }
        let fixtureURL = URL(fileURLWithPath: argument("--fixture-json"))
        let reportURL = URL(fileURLWithPath: argument("--report"))
        let duration = min(30, max(0.2, Double(argument("--seconds", fallback: "7")) ?? 7))
        let fps = Int(argument("--fps", fallback: "10")) ?? 10
        let width = Int(argument("--width", fallback: "960")) ?? 960
        let isStatic = CommandLine.arguments.contains("--static")
        let isCancellation = CommandLine.arguments.contains("--cancel-recording")
        Task { @MainActor in
            var report: [String: Any] = ["requestedSeconds": duration, "fps": fps, "width": width]
            var success = false
            do {
                let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
                let temporaryDirectory = FileManager.default.temporaryDirectory
                let existingTemporaryGIFs = Set(
                    (try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path))
                        .filter { $0.hasPrefix("ScreenshotLab-") && $0.hasSuffix(".gif") }
                )
                let frame = fixture.windowFrame.cgRect
                let screenFrame = fixture.screenFrame.cgRect
                let region = GIFCaptureRegion(
                    displayID: fixture.displayID,
                    screenFrame: screenFrame,
                    selection: frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
                )
                let recorder = GIFRecorder(
                    framesPerSecond: fps, maximumWidth: width,
                    automaticSaveDirectory: reportURL.deletingLastPathComponent()
                )
                var result: Result<URL, Error>?
                var captured = 0
                var encoded = 0
                recorder.onFinish = { result = $0 }
                recorder.onProgress = { _, frames, callbacks in
                    captured = callbacks
                    encoded = frames
                }
                let started = ProcessInfo.processInfo.systemUptime
                try await recorder.start(region: region)
                let recordingStart = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                recorder.stop(saveTo: reportURL.deletingLastPathComponent(), save: !isCancellation)
                for _ in 0..<200 {
                    if result != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                report["captureCallbacks"] = captured
                report["encodedProgress"] = encoded
                report["startLatency"] = recordingStart - started
                report["wallSeconds"] = ProcessInfo.processInfo.systemUptime - recordingStart
                guard let result else {
                    throw NSError(domain: "GIFMotionTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recorder did not finish within 20 seconds"])
                }
                if isCancellation {
                    if case .failure(let error) = result, error is CancellationError {
                        let remainingTemporaryGIFs = Set(
                            (try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path))
                                .filter { $0.hasPrefix("ScreenshotLab-") && $0.hasSuffix(".gif") }
                        ).subtracting(existingTemporaryGIFs)
                        let savedGIFs = try FileManager.default.contentsOfDirectory(atPath: reportURL.deletingLastPathComponent().path)
                            .filter { $0.hasSuffix(".gif") }
                        success = remainingTemporaryGIFs.isEmpty && savedGIFs.isEmpty
                        report["cancelledWithoutFiles"] = success
                    }
                } else {
                    let url = try result.get()
                    report["file"] = url.path
                    guard let source = CGImageSourceCreateWithURL(
                        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
                    ) else {
                        throw GIFEncoderError.encodeFailed
                    }
                    let count = CGImageSourceGetCount(source)
                    var signatures: [String] = []
                    var seconds = 0.0
                    var outputWidth = 0
                    for index in 0..<count {
                        autoreleasepool {
                        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                        seconds += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                            ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
                        guard let image = CGImageSourceCreateImageAtIndex(
                                source, index, [kCGImageSourceShouldCache: false] as CFDictionary
                              ),
                              let context = CGContext(
                                data: nil, width: 64, height: 36, bitsPerComponent: 8,
                                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                              ), let data = context.data else { return }
                        outputWidth = image.width
                        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 36))
                        let signature = SHA256.hash(data: Data(bytes: data, count: 64 * 36 * 4))
                        signatures.append(signature.map { String(format: "%02x", $0) }.joined())
                        if index == 0 || index == count / 2 || index == count - 1 {
                            try? ImageOutput.writePNG(image, to: reportURL.deletingLastPathComponent().appendingPathComponent("frame-\(index).png"))
                        }
                        }
                    }
                    let tail = Array(signatures.suffix(max(2, fps)))
                    let distinct = Set(signatures).count
                    let tailDistinct = Set(tail).count
                    let expectedFrames = Int((duration * Double(fps)).rounded())
                    let durationOK = abs(seconds - duration) <= max(0.15, 2 / Double(fps))
                    let delayQuantizationOK = abs(seconds - Double(count) / Double(fps)) <= 0.011
                    let framesOK = abs(count - expectedFrames) <= max(2, fps / 4)
                    let motionOK = isStatic ? distinct <= 2 : (
                        distinct >= max(5, Int(Double(count) * 0.7))
                        && tailDistinct >= max(3, Int(Double(tail.count) * 0.6))
                    )
                    success = durationOK && delayQuantizationOK && framesOK && motionOK
                        && signatures.count == count && outputWidth == width
                    report["frames"] = count
                    report["distinctFrames"] = distinct
                    report["tailDistinctFrames"] = tailDistinct
                    report["durationSeconds"] = seconds
                    report["outputWidth"] = outputWidth
                    report["durationOK"] = durationOK
                    report["delayQuantizationOK"] = delayQuantizationOK
                    report["framesOK"] = framesOK
                    report["motionOK"] = motionOK
                }
            } catch {
                report["error"] = error.localizedDescription
            }
            report["pass"] = success
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .atomic)
            }
            exit(success ? 0 : 1)
        }
    }
}
