public struct BrightnessMapping: Equatable {
    public let hardwareFraction: Double
    public let softwareDimmingFactor: Double

    public static func make(fraction: Double, switchover: Double) -> Self {
        let target = min(1, max(0, fraction))
        let point = min(0.6, max(0, switchover))
        let dimming = point > 0 && target < point ? target / point : 1
        return Self(hardwareFraction: target, softwareDimmingFactor: dimming)
    }

    public static func sliderFraction(forHardwareFraction fraction: Double) -> Double {
        min(1, max(0, fraction))
    }
}
