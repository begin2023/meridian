import AppKit
import CoreGraphics

/// 滚动事件来源判别：触控板 / 鼠标 / 自合成 / 远程平滑。
enum ScrollEventClassifier {
    /// 平滑管线发出的自合成事件标记，防回环。
    static let syntheticMarker: Int64 = 0x5343524C41424F53 // "SCRLABOS"

    /// phase 字段任一非零即为触控板；scrollCount 非零同样是触控板特征。
    /// 鼠标滚轮的事件这两个字段恒为 0。
    static func isTrackpad(_ event: CGEvent) -> Bool {
        if event.getDoubleValueField(.scrollWheelEventMomentumPhase) != 0 {
            return true
        }
        if event.getDoubleValueField(.scrollWheelEventScrollPhase) != 0 {
            return true
        }
        if event.getDoubleValueField(.scrollWheelEventScrollCount) != 0 {
            return true
        }
        // Logitech Options 等注入器合成的鼠标事件不带 phase，按鼠标处理。
        if let optionsBundleID = Bundle(for: BundleToken.self).bundleIdentifier {
            _ = optionsBundleID // 占位，避免未使用告警；真实判断见 eventSourceIsInjector
        }
        return eventSourceIsInjector(event)
    }

    /// 远程桌面（向日葵/ToDesk/RDP 类）发来的 isContinuous=1 事件已是平滑后的，
    /// 不做本地平滑。
    static func isRemoteSmoothed(_ event: CGEvent) -> Bool {
        guard event.getDoubleValueField(.scrollWheelEventIsContinuous) == 1.0 else {
            return false
        }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard sourcePID != 0, sourcePID != pid_t(ProcessInfo.processInfo.processIdentifier) else {
            return false
        }
        guard let app = NSRunningApplication(processIdentifier: pid_t(sourcePID)) else {
            return false
        }
        // 常见远控软件的 bundle id 前缀
        let remotePrefixes = [
            "com.sunlogin.",
            "com.oray.",
            "com.todesk.",
            "com.rdesktop.",
            "com.microsoft.rdc",
            "com.teamviewer.",
            "com.anydesk.",
        ]
        if let bundleID = app.bundleIdentifier, remotePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        return false
    }

    static func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }

    /// 注入器进程判定缓存（滚动事件热路径上避免每条事件都查 NSRunningApplication）。
    private static var injectorCacheLock = os_unfair_lock_s()
    private static var injectorCachePID: pid_t = 0
    private static var injectorCacheResult = false

    private static func eventSourceIsInjector(_ event: CGEvent) -> Bool {
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard sourcePID != 0 else { return false }
        let pid = pid_t(sourcePID)
        os_unfair_lock_lock(&injectorCacheLock)
        if pid == injectorCachePID {
            let cached = injectorCacheResult
            os_unfair_lock_unlock(&injectorCacheLock)
            return cached
        }
        os_unfair_lock_unlock(&injectorCacheLock)

        var result = false
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            let injectorPrefixes = [
                "com.logitech.",
                "com.Logitech.",
            ]
            result = injectorPrefixes.contains { bundleID.hasPrefix($0) }
        }
        os_unfair_lock_lock(&injectorCacheLock)
        injectorCachePID = pid
        injectorCacheResult = result
        os_unfair_lock_unlock(&injectorCacheLock)
        return result
    }
}

private final class BundleToken {}
