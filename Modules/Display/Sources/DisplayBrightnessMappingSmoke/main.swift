import BrightnessMapping
import Foundation

@main
struct DisplayBrightnessMappingSmoke {
    static func main() {
        var previousHardwareFraction = -1.0
        for percent in stride(from: 0, through: 100, by: 5) {
            let target = Double(percent) / 100
            let mapping = BrightnessMapping.make(fraction: target, switchover: 0.25)
            precondition(abs(mapping.hardwareFraction - target) < 1e-12)
            precondition(mapping.hardwareFraction >= previousHardwareFraction)
            previousHardwareFraction = mapping.hardwareFraction
        }

        let below = BrightnessMapping.make(fraction: 0.24, switchover: 0.25)
        let boundary = BrightnessMapping.make(fraction: 0.25, switchover: 0.25)
        let above = BrightnessMapping.make(fraction: 0.26, switchover: 0.25)
        precondition(abs(below.softwareDimmingFactor - 0.96) < 1e-12)
        precondition(boundary.softwareDimmingFactor == 1)
        precondition(above.softwareDimmingFactor == 1)
        precondition(boundary.hardwareFraction == 0.25)
        precondition(above.hardwareFraction == 0.26)
        precondition(BrightnessMapping.sliderFraction(forHardwareFraction: 0.25) == 0.25)
        precondition(BrightnessMapping.sliderFraction(forHardwareFraction: -0.2) == 0)
        precondition(BrightnessMapping.sliderFraction(forHardwareFraction: 1.2) == 1)

        print("DISPLAY_BRIGHTNESS_MAPPING_SMOKE_PASS")
    }
}
