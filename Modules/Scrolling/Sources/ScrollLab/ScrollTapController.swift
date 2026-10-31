import AppKit
import ApplicationServices
import CoreGraphics

/// CGEventTap 生命周期管理。
/// 需要"辅助功能"权限；被系统禁用时自动重装，并终止进行中的动画。
final class ScrollTapController {
    private var scrollTap: CFMachPort?
    private var clickTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var clickRunLoopSource: CFRunLoopSource?

    /// 引擎判定回调：返回处理结果（放行 / 吞掉）。
    var scrollHandler: ((CGEvent) -> Unmanaged<CGEvent>?)?
    /// 左键点击回调（终止动画）。
    var clickHandler: (() -> Void)?

    private(set) var isActive = false

    var isAccessible: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统辅助功能授权引导：macOS 不会主动弹窗，必须由应用调用
    /// 带 prompt 选项的检查，系统才会把本应用加入辅助功能列表并弹确认框。
    @discardableResult
    static func promptAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func enable() {
        guard !isActive else { return }
        guard isAccessible else {
            NSLog("ScrollLab: accessibility permission missing, tap not installed")
            return
        }
        let scrollMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        scrollTap = install(
            mask: scrollMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                let controller = Unmanaged<ScrollTapController>.fromOpaque(refcon!).takeUnretainedValue()
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    controller.handleTapDisabled()
                    return Unmanaged.passUnretained(event)
                case .scrollWheel:
                    return controller.scrollHandler?(event) ?? Unmanaged.passUnretained(event)
                default:
                    return Unmanaged.passUnretained(event)
                }
            },
            listenOnly: false
        )
        let clickMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        clickTap = install(
            mask: clickMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                let controller = Unmanaged<ScrollTapController>.fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    controller.handleClickTapDisabled()
                    return Unmanaged.passUnretained(event)
                }
                if type == .leftMouseDown {
                    controller.clickHandler?()
                }
                return Unmanaged.passUnretained(event)
            },
            listenOnly: true
        )
        isActive = scrollTap != nil
        if isActive {
            NSLog("ScrollLab: scroll tap installed")
        }
    }

    func disable() {
        guard isActive || scrollTap != nil || clickTap != nil else { return }
        if let tap = scrollTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            runLoopSource = nil
            CFMachPortInvalidate(tap)
        }
        if let tap = clickTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = clickRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            clickRunLoopSource = nil
            CFMachPortInvalidate(tap)
        }
        clickTap = nil
        scrollTap = nil
        isActive = false
        ScrollAnimator.shared.stop()
    }

    private func install(mask: CGEventMask, callback: @escaping CGEventTapCallBack, listenOnly: Bool) -> CFMachPort? {
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("ScrollLab: CGEventTapCreate failed (accessibility permission?)")
            return nil
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if listenOnly {
            clickRunLoopSource = source
        } else {
            runLoopSource = source
        }
        return tap
    }

    private func handleTapDisabled() {
        ScrollAnimator.shared.stop()
        if let tap = scrollTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handleClickTapDisabled() {
        if let clickTap {
            CGEvent.tapEnable(tap: clickTap, enable: true)
        }
    }
}
