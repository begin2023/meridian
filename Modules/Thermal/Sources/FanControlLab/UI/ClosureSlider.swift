import AppKit

/// target 自持的滑块。
final class ClosureSlider: NSSlider {
    var handler: (() -> Void)?

    init(value: Double, minValue: Double, maxValue: Double) {
        super.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
        self.target = self
        self.action = #selector(moved)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func moved() {
        handler?()
    }
}
