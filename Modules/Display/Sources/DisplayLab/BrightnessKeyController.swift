import AppKit
import CoreGraphics
import DisplayCore

/// Takes over the F1/F2 media keys (NX_KEYTYPE_BRIGHTNESS_DOWN/UP) so they
/// adjust external display brightness via DDC — the same slot macOS only uses
/// for built-in panels. Swallowing events requires the Input Monitoring
/// permission; without it the tap cannot be created and the preference row
/// shows an authorization button.
final class BrightnessKeyController {
    var onPermissionMissing: (() -> Void)?
    /// 按键调节后在主线程回调，便于界面同步滑块。
    var onAdjusted: (() -> Void)?

    private var eventTap: CFMachPort?
    private var tapEnabled = false
    private let settings = AppSettings.shared
    weak var displayManager: DisplayManager?

    // ev_keymap.h: BRIGHTNESS_UP/DOWN 是 2/3；21/22 是键盘背光（ILLUMINATION）。
    private static let brightnessUpKeyType = 2    // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDownKeyType = 3  // NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let systemDefinedMask = CGEventMask(1 << 14) // NSSystemDefined

    var permissionAvailable: Bool {
        eventTap != nil
    }

    func start() {
        stop()
        guard settings.takeOverBrightnessKeys else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let controller = Unmanaged<BrightnessKeyController>.fromOpaque(userInfo!).takeUnretainedValue()
            if controller.handleSystemDefined(event) {
                return nil // swallow the key
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.systemDefinedMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("DisplayLab: brightness key tap unavailable (missing Input Monitoring permission?)")
            onPermissionMissing?()
            return
        }

        eventTap = tap
        CGEvent.tapEnable(tap: tap, enable: true)
        RunLoop.main.add(tap, forMode: .common)
        tapEnabled = true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            let machPort = eventTap
            RunLoop.main.perform {
                CFMachPortInvalidate(machPort)
            }
        }
        eventTap = nil
        tapEnabled = false
    }

    /// Returns true when the event is a brightness media key this controller
    /// consumes. Subtype 8 of NSSystemDefined is auxControlButtons (media keys).
    private func handleSystemDefined(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return false
        }

        let data1 = nsEvent.data1
        let keyType = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0xFF00) >> 8

        let direction: Double
        switch keyType {
        case Self.brightnessUpKeyType:
            direction = 1
        case Self.brightnessDownKeyType:
            direction = -1
        default:
            return false
        }

        // 只处理 keyDown（10）时调亮度；keyUp（11）也一并吞掉，避免系统再处理一次。
        if keyState == 10 {
            adjustBrightness(step: direction * 0.05)
        }
        return true
    }

    private func adjustBrightness(step: Double) {
        guard let displayManager else { return }
        for display in displayManager.displays {
            guard let controller = displayManager.brightnessController(for: display.identifier),
                  controller.backendKind == .ddc || controller.backendKind == .apple else {
                continue
            }
            let current = displayManager.cachedBrightness(for: display.identifier)
            let target = min(1, max(0, current + step))
            displayManager.updateCachedBrightness(target, for: display.identifier)
            controller.setTarget(target, smooth: false)
        }
        onAdjusted?()
    }
}
