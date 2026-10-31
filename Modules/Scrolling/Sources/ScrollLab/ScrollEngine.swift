import AppKit
import CoreGraphics

/// 滚动事件判定与分发：触控板放行、例外匹配、反向滚轮、平滑管线接管。
enum ScrollEngine {
    /// 引擎观察到的最近一次判定，供自检与诊断。
    struct LastDecision {
        var kind: String = "none"
        var reversedY = false
        var reversedX = false
        var smoothed = false
    }

    private static var decisionLock = os_unfair_lock_s()
    private static var _lastDecision = LastDecision()
    private static var _syntheticFrames: Int = 0

    static var lastDecision: LastDecision {
        os_unfair_lock_lock(&decisionLock)
        defer { os_unfair_lock_unlock(&decisionLock) }
        return _lastDecision
    }

    /// 自检探针观测到的自合成帧数（引擎发出的平滑帧计数）。
    static var syntheticFrames: Int {
        os_unfair_lock_lock(&decisionLock)
        defer { os_unfair_lock_unlock(&decisionLock) }
        return _syntheticFrames
    }

    static func resetDiagnostics() {
        os_unfair_lock_lock(&decisionLock)
        _lastDecision = LastDecision()
        _syntheticFrames = 0
        os_unfair_lock_unlock(&decisionLock)
    }

    private static func record(_ mutate: (inout LastDecision) -> Void) {
        os_unfair_lock_lock(&decisionLock)
        mutate(&_lastDecision)
        let decision = _lastDecision
        os_unfair_lock_unlock(&decisionLock)
        if ProcessInfo.processInfo.environment["SCROLLLAB_DEBUG"] == "1" {
            NSLog("ScrollLab engine: kind=\(decision.kind) reversedY=\(decision.reversedY) reversedX=\(decision.reversedX) smoothed=\(decision.smoothed)")
        }
    }

    /// 事件 tap 的滚动回调主逻辑。返回 nil 表示吞掉事件。
    static func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 自合成事件放行，防回环
        if ScrollEventClassifier.isSynthetic(event) {
            record { $0.kind = "synthetic" }
            return Unmanaged.passUnretained(event)
        }
        if ProcessInfo.processInfo.environment["SCROLLLAB_DEBUG"] == "1" {
            let targetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
            let location = event.location
            NSLog("ScrollLab engine: seen targetPID=\(targetPID) location=(\(location.x), \(location.y))")
        }
        guard AppSettings.shared.enabled else {
            record { $0.kind = "disabled" }
            return Unmanaged.passUnretained(event)
        }

        var snapshot = ScrollWheelSnapshot(event: event)
        guard snapshot.hasVerticalDelta || snapshot.hasHorizontalDelta else {
            record { $0.kind = "empty" }
            return Unmanaged.passUnretained(event)
        }

        // 触控板事件不做任何处理
        if ScrollEventClassifier.isTrackpad(event) {
            record { $0.kind = "trackpad" }
            return Unmanaged.passUnretained(event)
        }
        // 远控软件已平滑的事件放行
        if ScrollEventClassifier.isRemoteSmoothed(event) {
            record { $0.kind = "remote" }
            return Unmanaged.passUnretained(event)
        }

        // 解析目标应用与例外配置；未命中白名单时事件完全放行
        let match = resolveException(for: event)
        if case .notListed = match {
            record { $0.kind = "not-listed" }
            return Unmanaged.passUnretained(event)
        }
        var target: AppException?
        if case .exception(let exception) = match {
            target = exception
        }
        let plan = resolvePlan(for: target)

        record { decision in
            decision.kind = target == nil ? "global" : "exception"
            decision.reversedY = false
            decision.reversedX = false
            decision.smoothed = false
        }

        // ---- 反向滚轮 ----
        if plan.reverseVertical, snapshot.hasVerticalDelta {
            snapshot.reverseVertical()
            record { $0.reversedY = true }
        }
        if plan.reverseHorizontal, snapshot.hasHorizontalDelta {
            snapshot.reverseHorizontal()
            record { $0.reversedX = true }
        }

        // ---- 平滑接管 ----
        let shouldSmoothY = plan.smooth && plan.smoothVertical && snapshot.hasVerticalDelta
        let shouldSmoothX = plan.smooth && plan.smoothHorizontal && snapshot.hasHorizontalDelta

        var smoothY = 0.0
        var smoothX = 0.0
        if shouldSmoothY {
            var value = snapshot.y.usableValue
            if abs(value) < plan.step {
                value = ScrollWheelSnapshot.normalized(value, threshold: plan.step)
            }
            smoothY = value
        }
        if shouldSmoothX {
            var value = snapshot.x.usableValue
            if abs(value) < plan.step {
                value = ScrollWheelSnapshot.normalized(value, threshold: plan.step)
            }
            smoothX = value
        }

        if smoothY != 0 || smoothX != 0 {
            record { $0.smoothed = true }
            ScrollAnimator.shared.enqueue(event: event, yValue: smoothY, xValue: smoothX, speed: plan.speed,
                                           duration: plan.duration)
        }

        let passthroughY = snapshot.hasVerticalDelta && !shouldSmoothY
        let passthroughX = snapshot.hasHorizontalDelta && !shouldSmoothX

        if passthroughY || passthroughX {
            // 混合情形：被平滑的轴清零，其余轴放行原事件
            if shouldSmoothY { snapshot.clearVertical() }
            if shouldSmoothX { snapshot.clearHorizontal() }
            return Unmanaged.passUnretained(event)
        }
        if smoothY != 0 || smoothX != 0 {
            // 全部轴被接管：吞掉原事件
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - 计划解析

    struct Plan {
        var reverseVertical = false
        var reverseHorizontal = false
        var smooth = false
        var smoothVertical = false
        var smoothHorizontal = false
        var step = AppSettings.defaultStep
        var speed = AppSettings.defaultSpeed
        var duration = AppSettings.defaultDuration
    }

    enum ExceptionMatch {
        case exception(AppException)
        /// 白名单模式下未命中列表
        case notListed
    }

    static func resolveException(for event: CGEvent) -> ExceptionMatch? {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        guard pid > 1, let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        let settings = AppSettings.shared
        let candidates = [app.bundleURL?.path, app.executableURL?.path].compactMap { $0 }
        let match = settings.exceptions.first { exception in
            candidates.contains(exception.bundlePath) || candidates.contains(exception.executablePath)
        }
        if let match {
            return .exception(match)
        }
        // 白名单模式：不在列表中的应用不处理（反向/平滑都关闭）
        if settings.allowlist {
            return .notListed
        }
        return nil
    }

    static func resolvePlan(for exception: AppException?) -> Plan {
        let settings = AppSettings.shared
        var plan = Plan()
        if let exception, !exception.inherit {
            plan.reverseVertical = exception.reverse && exception.reverseVertical
            plan.reverseHorizontal = exception.reverse && exception.reverseHorizontal
            plan.smooth = exception.smooth
            plan.smoothVertical = exception.smooth && exception.smoothVertical
            plan.smoothHorizontal = exception.smooth && exception.smoothHorizontal
            plan.step = exception.step
            plan.speed = exception.speed
            plan.duration = exception.duration
            return plan
        }
        plan.reverseVertical = settings.reverse && settings.reverseVertical
        plan.reverseHorizontal = settings.reverse && settings.reverseHorizontal
        plan.smooth = settings.smooth
        plan.smoothVertical = settings.smooth && settings.smoothVertical
        plan.smoothHorizontal = settings.smooth && settings.smoothHorizontal
        plan.step = settings.step
        plan.speed = settings.speed
        plan.duration = settings.duration
        return plan
    }
}
