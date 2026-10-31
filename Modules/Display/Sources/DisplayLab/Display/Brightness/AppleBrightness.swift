import AppKit
import CoreGraphics

/// Access to the private DisplayServices brightness functions used for Apple
/// displays. The framework is not stubbed in the CommandLineTools SDK, so the
/// symbols resolve through dlopen at runtime; a missing framework or symbol
/// yields nil and brightness control degrades to other backends.
final class AppleBrightness {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightnessFn = @convention(c) (CGDirectDisplayID) -> Bool

    private let getBrightness: GetBrightnessFn
    private let setBrightness: SetBrightnessFn
    private let canChangeBrightness: CanChangeBrightnessFn?

    private init(
        getBrightness: @escaping GetBrightnessFn,
        setBrightness: @escaping SetBrightnessFn,
        canChangeBrightness: CanChangeBrightnessFn?
    ) {
        self.getBrightness = getBrightness
        self.setBrightness = setBrightness
        self.canChangeBrightness = canChangeBrightness
    }

    private static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    static func make() -> AppleBrightness? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            return nil
        }
        guard let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            return nil
        }
        return AppleBrightness(
            getBrightness: unsafeBitCast(getSymbol, to: GetBrightnessFn.self),
            setBrightness: unsafeBitCast(setSymbol, to: SetBrightnessFn.self),
            canChangeBrightness: dlsym(handle, "DisplayServicesCanChangeBrightness")
                .map { unsafeBitCast($0, to: CanChangeBrightnessFn.self) }
        )
    }

    func canChange(_ display: CGDirectDisplayID) -> Bool {
        canChangeBrightness?(display) ?? true
    }

    /// Returns the brightness as a 0...1 fraction, or nil when the framework
    /// rejects the read.
    func currentFraction(for display: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return nil }
        return Double(min(1, max(0, value)))
    }

    func apply(fraction: Double, to display: CGDirectDisplayID) -> Bool {
        setBrightness(display, Float(min(1, max(0, fraction)))) == 0
    }
}
