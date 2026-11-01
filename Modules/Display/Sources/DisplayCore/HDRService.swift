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
        // readback below is authoritative. 外接屏切换 HDR 要重新协商链路，实测约 1–2 秒。
        if waitForState(enabled, on: display, seconds: 2.5) {
            return enabled
        }
        // 实测（macOS 27.2，AOC Q27G2G3R4B）：用 CGS 私有接口切过模式后，WindowServer 有时只记下
        // “output mode change”请求却不执行，直到下一次 modeset 才生效（日志里链路一直停在
        // YCbCr444_8bit）。原样重设一次当前模式就能把挂起的请求冲下去，分辨率和刷新率不变。
        reapplyCurrentMode(display)
        if waitForState(enabled, on: display, seconds: 3) {
            return enabled
        }
        _ = functions?.set(display, enabled)
        _ = waitForState(enabled, on: display, seconds: 3)
        return isEnabled(display)
    }

    private static func waitForState(_ enabled: Bool, on display: CGDirectDisplayID, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            usleep(100_000)
            if isEnabled(display) == enabled { return true }
        }
        return false
    }

    private static func reapplyCurrentMode(_ display: CGDirectDisplayID) {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return
        }
        CGCompleteDisplayConfiguration(config, .forSession)
        NSLog("DisplayLab HDR: request pending, re-applied current mode %u to flush it", mode.ioDisplayModeID)
    }
}
