import AppKit
import CoreGraphics

/// 纯逻辑自检（无需辅助功能权限）：插值数学、反向变换、计划解析、设置持久化。
enum SelfTest {
    static func run() {
        var failures = 0
        func check(_ name: String, _ condition: Bool, detail: String = "") {
            if condition {
                print("PASS \(name)")
            } else {
                failures += 1
                print("FAIL \(name) \(detail)")
            }
        }

        // ---- transition 映射 ----
        let transitionDefault = ScrollInterpolator.transitionFactor(duration: 4.35)
        check("transition-default", abs(transitionDefault - 0.085) < 0.002, detail: "got \(transitionDefault)")
        let transitionZero = ScrollInterpolator.transitionFactor(duration: 0)
        check("transition-zero", transitionZero == 1.0, detail: "got \(transitionZero)")
        let transitionSlow = ScrollInterpolator.transitionFactor(duration: 5.0)
        check("transition-slow", transitionSlow > 0.01 && transitionSlow < 0.03, detail: "got \(transitionSlow)")

        // ---- 帧插值：指数衰减收敛 ----
        var current = 0.0
        let buffer = 90.72 // 33.6 × 2.7
        var frames = 0
        var total = 0.0
        while abs(buffer - current) > 0.5 && frames < 600 {
            let delta = ScrollInterpolator.frameDelta(current: current, buffer: buffer, transition: transitionDefault)
            current += delta
            total += delta
            frames += 1
        }
        check("lerp-converges", frames > 30 && frames < 120, detail: "frames=\(frames) total=\(total)")
        check("lerp-total", abs(total - buffer) < 1.5, detail: "total=\(total) buffer=\(buffer)")

        // ---- 起步消抖：首帧输出 0，随后追踪原始帧值 ----
        var filter = ScrollPolishFilter()
        let first = filter.fill(nextValue: 10)
        let second = filter.fill(nextValue: 10)
        check("polish-first-zero", first == 0, detail: "got \(first)")
        check("polish-second-tracks", abs(second - 2.3) < 0.001, detail: "got \(second)")
        var late = second
        for _ in 0..<20 { late = filter.fill(nextValue: 10) }
        check("polish-converges", abs(late - 10) < 0.5, detail: "got \(late)")

        // ---- 反向滚轮：三个字段全部取负 ----
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 3,
            wheel2: 0,
            wheel3: 0
        )!
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 3)
        var snapshot = ScrollWheelSnapshot(event: event)
        check("axis-y-valid", snapshot.hasVerticalDelta, detail: "\(snapshot.y)")
        // Event2 构造器把行值放大为像素点距（3 行 → point 30），usable 优先取点距
        check("axis-y-usability", snapshot.y.usableValue == 30, detail: "got \(snapshot.y.usableValue)")
        snapshot.reverseVertical()
        check("reverse-integer", event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3, detail: "got \(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))")
        check("reverse-fixed", event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -3, detail: "got \(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))")
        check("reverse-usable", snapshot.y.usableValue == -30, detail: "got \(snapshot.y.usableValue)")

        // 横向反向
        let hEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 2,
            wheel3: 0
        )!
        var hSnapshot = ScrollWheelSnapshot(event: hEvent)
        check("axis-x-valid", hSnapshot.hasHorizontalDelta)
        hSnapshot.reverseHorizontal()
        check("reverse-x", hEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -2, detail: "got \(hEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2))")

        // ---- 归一化：小步距抬升到 step，符号保留 ----
        check("normalize-positive", ScrollWheelSnapshot.normalized(3, threshold: 33.6) == 33.6)
        check("normalize-negative", ScrollWheelSnapshot.normalized(-3, threshold: 33.6) == -33.6)
        check("normalize-passthrough", ScrollWheelSnapshot.normalized(50, threshold: 33.6) == 50)

        // ---- 清零：被平滑的轴字段清零 ----
        let clearEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 5,
            wheel2: 2,
            wheel3: 0
        )!
        var clearSnapshot = ScrollWheelSnapshot(event: clearEvent)
        clearSnapshot.clearVertical()
        check("clear-y", clearEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0
            && clearEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == 0)

        // ---- 计划解析 ----
        var plan = ScrollEngine.resolvePlan(for: nil)
        check("plan-global-reverse", plan.reverseVertical && plan.reverseHorizontal)
        check("plan-global-smooth", plan.smooth && plan.smoothVertical && plan.smoothHorizontal)
        check("plan-global-step", plan.step == AppSettings.defaultStep)
        let exception = AppException(
            name: "Test", bundlePath: "/tmp/Test.app", executablePath: "/tmp/Test.app/Contents/MacOS/Test",
            inherit: false, reverse: true, reverseVertical: false, reverseHorizontal: true,
            smooth: false, smoothVertical: false, smoothHorizontal: false,
            step: 50, speed: 3, duration: 2
        )
        plan = ScrollEngine.resolvePlan(for: exception)
        check("plan-exception-no-reverse-y", plan.reverseVertical == false)
        check("plan-exception-reverse-x", plan.reverseHorizontal == true)
        check("plan-exception-no-smooth", plan.smooth == false)
        check("plan-exception-step", plan.step == 50)

        // ---- 合成事件标记 ----
        let marked = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        )!
        ScrollEventClassifier.markSynthetic(marked)
        check("synthetic-mark", ScrollEventClassifier.isSynthetic(marked))
        let unmarked = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        )!
        check("synthetic-unmarked", !ScrollEventClassifier.isSynthetic(unmarked))
        // 鼠标滚轮特征：phase 全零 → 非触控板
        check("mouse-not-trackpad", !ScrollEventClassifier.isTrackpad(unmarked))

        // ---- 设置持久化 ----
        let originalStep = AppSettings.shared.step
        AppSettings.shared.setStep(66.6)
        check("settings-set", AppSettings.shared.step == 66.6)
        AppSettings.shared.setStep(originalStep)
        check("settings-restore", AppSettings.shared.step == originalStep)

        // ---- 例外编解码 ----
        var encoded = [exception]
        if let raw = try? JSONEncoder().encode(encoded),
           let decoded = try? JSONDecoder().decode([AppException].self, from: raw) {
            check("exception-roundtrip", decoded == encoded)
        } else {
            check("exception-roundtrip", false)
        }
        encoded = []

        if failures == 0 {
            print("SELFTEST-RESULT pass")
            fflush(stdout)
            exit(0)
        }
        print("SELFTEST-RESULT fail failures=\(failures)")
        fflush(stdout)
        exit(1)
    }
}
