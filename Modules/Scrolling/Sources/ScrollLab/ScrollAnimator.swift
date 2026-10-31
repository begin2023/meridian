import AppKit
import CoreGraphics

/// 平滑滚动渲染引擎：缓冲目标值，按显示器刷新率逐帧收缩并发送合成滚动事件。
///
/// 行为规格（见 docs/reverse-engineering-notes.md）：
/// - 同方向续滚 buffer 累加，方向反转时缓冲重置、立即掉头；
/// - 每帧 frame = (buffer − current) × transition，current += frame；
/// - 帧值经起步消抖滤波后发送，幅值低于死区的帧静默；
/// - 合成事件复用捕获的事件模板（改写像素 delta、isContinuous=1、打标记），
///   CGEventPostToPid 直投目标进程；
/// - 输入停顿后残余距离仍在消耗则进入动量阶段；左键点击立即终止。
final class ScrollAnimator {
    /// 捕获的事件模板与投递目标，主线程写入，渲染线程只读快照。
    private struct Template {
        let event: CGEvent
        let targetPID: pid_t
        let capturedAt: CFTimeInterval
    }

    private var lock = os_unfair_lock_s()
    private var template: Template?
    private var generation: UInt64 = 0

    private var current = (y: 0.0, x: 0.0)
    private var buffer = (y: 0.0, x: 0.0)
    private var lastDirection = (y: 0.0, x: 0.0)
    private var polishY = ScrollPolishFilter()
    private var polishX = ScrollPolishFilter()

    // 输入节奏追踪（秒）
    private var lastInputTime: CFTimeInterval = 0
    private var manualInputEnded = true
    private var momentumActive = false
    private var momentumEndAt: CFTimeInterval?
    private var trackingEndAt: CFTimeInterval?

    private static let manualContinuationThreshold: CFTimeInterval = 0.18
    private static let manualSeparationThreshold: CFTimeInterval = 0.45
    private static let momentumEndDelay: CFTimeInterval = 0.13
    private static let trackingEndAdvance: CFTimeInterval = 0.04
    private static let eventTTL: CFTimeInterval = 5.0

    private var displayLink: CVDisplayLink?
    private var lastLinkCallbackTime: CFTimeInterval = 0
    private var lastRecreateAttempt: CFTimeInterval = 0
    /// 自检探针：已发送的平滑帧计数。
    private var postedFrameCount = 0

    var postedFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return postedFrameCount
    }

    func resetDiagnostics() {
        os_unfair_lock_lock(&lock)
        postedFrameCount = 0
        os_unfair_lock_unlock(&lock)
    }

    var isRunning: Bool {
        if let link = displayLink, CVDisplayLinkIsRunning(link) { return true }
        return false
    }

    // MARK: - 输入

    /// 捕获事件模板并送入缓冲。在事件 tap 回调（主线程 runloop）中调用。
    /// 当前动画使用的过渡参数；按应用例外的 duration 随每次入队更新（受 lock 保护）。
    private var activeDuration = AppSettings.defaultDuration

    func enqueue(event: CGEvent, yValue: Double, xValue: Double, speed: Double,
                 duration: Double = AppSettings.shared.duration) {
        guard let copied = event.copy() else { return }
        // 真实硬件事件由系统填写目标 PID；缺失时回退到前台应用
        var targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if targetPID <= 1, let frontmost = NSWorkspace.shared.frontmostApplication {
            targetPID = frontmost.processIdentifier
        }
        os_unfair_lock_lock(&lock)
        template = Template(event: copied, targetPID: targetPID, capturedAt: CFAbsoluteTimeGetCurrent())
        activeDuration = duration
        buffer.y = accumulate(buffer: buffer.y, value: yValue * speed, direction: yValue, previous: lastDirection.y, current: &current.y)
        buffer.x = accumulate(buffer: buffer.x, value: xValue * speed, direction: xValue, previous: lastDirection.x, current: &current.x)
        lastDirection = (y: yValue, x: xValue)

        let now = CFAbsoluteTimeGetCurrent()
        let interval = lastInputTime > 0 ? now - lastInputTime : nil
        let separatedByTime = interval.map { $0 >= Self.manualSeparationThreshold } ?? true
        let separated = manualInputEnded || separatedByTime
        manualInputEnded = false
        momentumActive = false
        momentumEndAt = nil
        trackingEndAt = nil
        lastInputTime = now
        os_unfair_lock_unlock(&lock)

        if separated {
            // 新一轮手势：清掉上一次的消抖状态，保证起步缓入重新生效
            os_unfair_lock_lock(&lock)
            polishY.reset()
            polishX.reset()
            os_unfair_lock_unlock(&lock)
        }
        tryStart()
    }

    private func accumulate(buffer: Double, value: Double, direction: Double, previous: Double, current: inout Double) -> Double {
        if direction * previous > 0 {
            return buffer + value
        }
        current = 0
        return value
    }

    /// 左键点击：立即终止动画（残余距离不再消耗）。
    func brake() {
        os_unfair_lock_lock(&lock)
        buffer = current
        manualInputEnded = true
        momentumActive = false
        momentumEndAt = nil
        os_unfair_lock_unlock(&lock)
    }

    /// 完全复位（设置变更 / tap 失效 / 收尾完成）。
    func reset() {
        os_unfair_lock_lock(&lock)
        generation &+= 1
        template = nil
        current = (0, 0)
        buffer = (0, 0)
        lastDirection = (0, 0)
        polishY.reset()
        polishX.reset()
        manualInputEnded = true
        momentumActive = false
        lastInputTime = 0
        momentumEndAt = nil
        trackingEndAt = nil
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - 渲染循环

    private func tryStart() {
        if let link = displayLink {
            if CVDisplayLinkIsRunning(link) { return }
            if CVDisplayLinkStart(link) == kCVReturnSuccess {
                lastLinkCallbackTime = CFAbsoluteTimeGetCurrent()
                return
            }
        }
        recreateLink()
    }

    @discardableResult
    private func recreateLink() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRecreateAttempt >= 3.0 else { return false }
        lastRecreateAttempt = now
        stopLink()
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let validLink = link else {
            displayLink = nil
            return false
        }
        CVDisplayLinkSetOutputCallback(validLink, { _, _, _, _, _, _ -> CVReturn in
            ScrollAnimator.shared.processFrame()
            return kCVReturnSuccess
        }, nil)
        displayLink = validLink
        lastLinkCallbackTime = CFAbsoluteTimeGetCurrent()
        if CVDisplayLinkStart(validLink) == kCVReturnSuccess {
            lastLinkCallbackTime = CFAbsoluteTimeGetCurrent()
            return true
        }
        return false
    }

    private func stopLink() {
        if let link = displayLink {
            if CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStop(link)
            }
        }
        displayLink = nil
    }

    func stop(reason: StopReason = .momentumEnd) {
        stopLink()
        // 失效旧代次的异步帧
        os_unfair_lock_lock(&lock)
        generation &+= 1
        os_unfair_lock_unlock(&lock)
        _ = reason
        reset()
    }

    enum StopReason {
        case momentumEnd
        case trackingEnd
        case tapDisabled
    }

    // MARK: - 帧处理（CVDisplayLink 线程）

    private func processFrame() {
        os_unfair_lock_lock(&lock)
        lastLinkCallbackTime = CFAbsoluteTimeGetCurrent()

        let settings = AppSettings.shared
        let transition = ScrollInterpolator.transitionFactor(duration: activeDuration)
        let deadZone = settings.deadZone
        let simTrackpad = settings.smoothSimTrackpad

        let frameY = ScrollInterpolator.frameDelta(current: current.y, buffer: buffer.y, transition: transition)
        let frameX = ScrollInterpolator.frameDelta(current: current.x, buffer: buffer.x, transition: transition)
        current.y += frameY
        current.x += frameX

        let outputY = polishY.fill(nextValue: frameY)
        let outputX = polishX.fill(nextValue: frameX)
        // 消抖滤波输出的是"追踪值"，幅值可能仍高于原始帧值；死区用输出值判定
        let outputMagnitude = max(abs(outputY), abs(outputX))

        let now = CFAbsoluteTimeGetCurrent()
        var stopReason: StopReason?

        // 安全网：动画异常不收敛时最多跑 6 秒强制收链（正常衰减远短于此）
        if lastInputTime > 0, now - lastInputTime > 6.0 {
            stopReason = .trackingEnd
        }

        // 手动输入结束判定：距最后输入超过续滚阈值
        if stopReason == nil,
           !manualInputEnded, lastInputTime > 0, now - lastInputTime > Self.manualContinuationThreshold {
            manualInputEnded = true
            if trackingEndAt == nil {
                trackingEndAt = now + Self.trackingEndAdvance
            }
        }

        // 动量阶段：输入结束后缓冲残余仍超死区
        let residual = max(abs(buffer.y - current.y), abs(buffer.x - current.x))
        if manualInputEnded, residual > deadZone {
            momentumActive = true
            momentumEndAt = nil
            trackingEndAt = nil
        } else if momentumActive, residual <= deadZone {
            if momentumEndAt == nil {
                momentumEndAt = now + Self.momentumEndDelay
            }
        } else if !momentumActive {
            momentumEndAt = nil
        }

        if let scheduled = momentumEndAt, momentumActive, now >= scheduled {
            momentumEndAt = nil
            momentumActive = false
            stopReason = .momentumEnd
        }
        if stopReason == nil,
           manualInputEnded, !momentumActive, residual <= deadZone,
           outputMagnitude <= deadZone,
           let scheduled = trackingEndAt, now >= scheduled {
            trackingEndAt = nil
            stopReason = .trackingEnd
        }

        let templateSnapshot = template
        let currentGeneration = generation
        os_unfair_lock_unlock(&lock)

        if outputMagnitude > deadZone, let snapshot = templateSnapshot {
            os_unfair_lock_lock(&lock)
            postedFrameCount += 1
            os_unfair_lock_unlock(&lock)
            postFrame(
                template: snapshot,
                y: outputY,
                x: outputX,
                generation: currentGeneration,
                simTrackpad: simTrackpad
            )
        }

        if let reason = stopReason {
            stop(reason: reason)
        }
    }

    private func postFrame(template: Template, y: Double, x: Double, generation frameGeneration: UInt64, simTrackpad: Bool) {
        // 代次/TTL 双重校验：过期模板（如刚被 reset）不发送，防止恢复后跳变
        os_unfair_lock_lock(&lock)
        let validGeneration = frameGeneration == generation
        let validTTL = CFAbsoluteTimeGetCurrent() - template.capturedAt <= Self.eventTTL
        os_unfair_lock_unlock(&lock)
        guard validGeneration, validTTL else { return }

        let event = template.event.copy()
        guard let event else { return }
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1.0)
        if simTrackpad {
            // 触控板相位模拟：让目标进程按触控板语义处理
            event.setDoubleValueField(.scrollWheelEventScrollPhase, value: phaseValue(for: .began))
            event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: 0)
        }
        ScrollEventClassifier.markSynthetic(event)
        if ProcessInfo.processInfo.environment["SCROLLLAB_DEBUG"] == "1" {
            NSLog("ScrollLab animator: post pid=\(template.targetPID) y=\(y) x=\(x)")
        }
        // 事件直接投递到目标进程，避免每帧重新命中测试
        // 与所有 tap 遍历挤占光标事件通道（表现为滚完之后鼠标移动卡顿）。
        // 模板来自真实硬件事件时该路径有效；合成测试模板缺 source 状态，
        // 用环境变量 SCROLLLAB_DELIVERY=cghid 强制走会话链（自动化测试用）。
        if !Self.forceCghidDelivery, template.targetPID > 1 {
            event.postToPid(template.targetPID)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    /// 自动化测试开关：合成模板的 postToPid 投递无效，测试时强制会话链。
    private static let forceCghidDelivery =
        ProcessInfo.processInfo.environment["SCROLLLAB_DELIVERY"] == "cghid"

    private enum SimPhase { case began, changed, ended }

    private func phaseValue(for phase: SimPhase) -> Double {
        // kCGScrollWheelEventScrollPhase 值域：1=began 2=changed 4=ended
        switch phase {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        }
    }
}

extension ScrollAnimator {
    static let shared = ScrollAnimator()
}
