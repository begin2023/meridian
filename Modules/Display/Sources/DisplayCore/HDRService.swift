import AppKit
import CoreGraphics
import Foundation

/// Runtime access to SkyLight HDR functions. Symbols resolve through
/// dlopen/dlsym because no SDK stub is available; missing symbols degrade
/// to "unsupported".
public enum HDRService {
    private typealias SupportsHDRModeFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias IsHDRModeEnabledFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias SetHDRModeEnabledFn = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private static var functions: (supports: SupportsHDRModeFn, isEnabled: IsHDRModeEnabledFn, set: SetHDRModeEnabledFn)? = {
        guard let handle = dlopen(skyLightPath, RTLD_LAZY) else {
            return nil
        }
        guard let supportsSymbol = dlsym(handle, "SLSDisplaySupportsHDRMode"),
              let enabledSymbol = dlsym(handle, "SLSDisplayIsHDRModeEnabled"),
              let setSymbol = dlsym(handle, "SLSDisplaySetHDRModeEnabled") else {
            return nil
        }
        return (
            unsafeBitCast(supportsSymbol, to: SupportsHDRModeFn.self),
            unsafeBitCast(enabledSymbol, to: IsHDRModeEnabledFn.self),
            unsafeBitCast(setSymbol, to: SetHDRModeEnabledFn.self)
        )
    }()

    public static var isAvailable: Bool {
        functions != nil
    }

    public static func supportsHDR(_ display: CGDirectDisplayID) -> Bool {
        functions?.supports(display) ?? false
    }

    public static func isEnabled(_ display: CGDirectDisplayID) -> Bool? {
        guard functions != nil, supportsHDR(display) else { return nil }
        return functions?.isEnabled(display)
    }

    /// Returns the applied state, or nil when the call failed or HDR is
    /// unsupported.
    @discardableResult
    public static func setEnabled(_ enabled: Bool, for display: CGDirectDisplayID) -> Bool? {
        guard functions != nil, supportsHDR(display) else { return nil }
        let status = functions?.set(display, enabled)
        guard status == 0 || status == nil else {
            NSLog("DisplayLab HDR: set failed with status \(String(describing: status))")
            return nil
        }
        // The setter returns before WindowServer applies the change; the
        // readback below is authoritative.
        var applied: Bool?
        for _ in 0..<10 {
            usleep(50_000)
            applied = isEnabled(display)
            if applied == enabled {
                break
            }
        }
        return applied
    }
}
