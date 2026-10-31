import AppKit
import CoreGraphics

/// 自检探针：在进程内验证事件 tap 生效——
/// 1) 合成一条"鼠标滚轮"事件（不带 phase，单位 delta）并投递到本进程；
/// 2) 通过 ScrollEngine.lastDecision 观察引擎是否看到了事件、是否应用了反向/平滑；
/// 3) 输出结构化结果供脚本断言。
enum TapSmokeProbe {
    static func run() {
        let trusted = AXIsProcessTrusted()
        print("TAPSMOKE accessible=\(trusted)")
        guard trusted else {
            print("TAPSMOKE-RESULT fail reason=accessibility")
            fflush(stdout)
            exit(2)
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").first else {
            print("TAPSMOKE-RESULT fail reason=self-not-running")
            fflush(stdout)
            exit(2)
        }

        ScrollEngine.resetDiagnostics()
        ScrollAnimator.shared.reset()
        ScrollAnimator.shared.resetDiagnostics()

        // 普通鼠标滚轮：整数行 delta=3，fixedPt=3，无 phase
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: -3,
            wheel2: 0,
            wheel3: 0
        )!
        event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setDoubleValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: 0)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(app.processIdentifier))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(app.processIdentifier))
        event.post(tap: .cghidEventTap)

        // 引擎在主 runloop 处理事件；轮询等待平滑动画发出若干合成帧
        let deadline = Date().addingTimeInterval(4.0)
        var decision = ScrollEngine.lastDecision
        while Date() < deadline {
            decision = ScrollEngine.lastDecision
            if ScrollAnimator.shared.postedFrames >= 10 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let frames = ScrollAnimator.shared.postedFrames
        print("TAPSMOKE decision kind=\(decision.kind) reversedY=\(decision.reversedY) smoothed=\(decision.smoothed) frames=\(frames)")
        let ok = decision.kind != "none" && decision.reversedY && frames >= 10
        print("TAPSMOKE-RESULT \(ok ? "pass" : "fail") kind=\(decision.kind) reversedY=\(decision.reversedY) smoothed=\(decision.smoothed) frames=\(frames)")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }
}
