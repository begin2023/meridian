import Foundation

/// 平滑滚动插值数学。
enum ScrollInterpolator {
    /// duration 滑杆值（0–5）→ 每帧收缩比例。duration 越大走越慢。
    /// 公式含 0.2 偏移以保证 duration=0 时比例为 1（瞬时到位）。
    static func transitionFactor(duration: Double) -> Double {
        let upperLimit = 5.0 + 0.2
        let value = 1 - (duration / upperLimit).squareRoot()
        return (value * 1000).rounded() / 1000
    }

    /// 每帧输出：剩余距离 × transition 比例（指数衰减模型）。
    static func frameDelta(current: Double, buffer: Double, transition: Double) -> Double {
        (buffer - current) * transition
    }

    /// 起步消抖滤波的收敛系数：输出以 0.23 的比例逐帧追踪原始帧值。
    static let polishFactor = 0.23
}

/// 单轴起步消抖滤波器。
/// 语义：输出值滞后原始帧值一帧，并以 polishFactor 指数追踪原始帧值——
/// 序列上等效于把帧值序列做一帧延迟的 S 形缓入，消除起步突跳。
struct ScrollPolishFilter {
    private var smoothed = 0.0

    /// 输入本帧原始帧值，返回应发送的值（上一次追踪值）。
    mutating func fill(nextValue: Double) -> Double {
        let output = smoothed
        smoothed += ScrollInterpolator.polishFactor * (nextValue - smoothed)
        return output
    }

    mutating func reset() {
        smoothed = 0
    }
}
