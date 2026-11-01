import Foundation

/// Night Shift and True Tone switches from the private CoreBrightness
/// framework, used to turn both off while an external display is in HDR mode
/// (same option as BetterDisplay's "Turn off Night Shift and True Tone in HDR
/// mode"). Everything resolves at runtime; missing classes degrade to no-ops.
final class BlueLightControl {
    static let shared = BlueLightControl()

    private let blueLight: NSObject?
    private let trueTone: NSObject?

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        blueLight = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
        trueTone = (NSClassFromString("CBTrueToneClient") as? NSObject.Type)?.init()
    }

    /// Whether Night Shift is tinting the screen right now (manual or schedule).
    /// Status layout `{BBBi{{ii}{ii}}QB}`. Measured on macOS 27.2: byte 1
    /// (`enabled`) follows the on/off state, byte 0 stays 1 even while off.
    var nightShiftActive: Bool {
        guard let blueLight else { return false }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard blueLight.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: blueLight), selector) else {
            return false
        }
        typealias StatusFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        var status = [UInt8](repeating: 0, count: 64)
        let ok = status.withUnsafeMutableBytes {
            unsafeBitCast(implementation, to: StatusFn.self)(blueLight, selector, $0.baseAddress!)
        }
        return ok && status[1] != 0
    }

    func setNightShift(_ enabled: Bool) {
        guard let blueLight else { return }
        let selector = NSSelectorFromString("setEnabled:")
        guard blueLight.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: blueLight), selector) else { return }
        typealias SetFn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(implementation, to: SetFn.self)(blueLight, selector, enabled)
    }

    /// True Tone only exists on supported Apple panels; third-party HDR
    /// monitors report `supported = false`.
    var trueToneActive: Bool {
        guard let trueTone, boolValue(trueTone, "supported"), boolValue(trueTone, "available") else { return false }
        return boolValue(trueTone, "enabled")
    }

    func setTrueTone(_ enabled: Bool) {
        guard let trueTone else { return }
        let selector = NSSelectorFromString("setEnabled:")
        guard trueTone.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: trueTone), selector) else { return }
        typealias SetFn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(implementation, to: SetFn.self)(trueTone, selector, enabled)
    }

    private func boolValue(_ object: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: object), selector) else { return false }
        typealias GetFn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: GetFn.self)(object, selector)
    }
}
