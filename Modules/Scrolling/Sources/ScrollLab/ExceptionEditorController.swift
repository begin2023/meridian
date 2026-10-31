import AppKit

/// 例外应用编辑弹窗：继承开关 + 反向/平滑覆盖 + 三滑杆。
final class ExceptionEditorController: NSWindowController {
    private static var activeController: ExceptionEditorController?

    private var exceptionIndex: Int
    private let settings = AppSettings.shared

    private let inheritCheckbox = NSButton(checkboxWithTitle: "继承全局设置", target: nil, action: nil)
    private let reverseCheckbox = NSButton(checkboxWithTitle: "反向滚轮", target: nil, action: nil)
    private let reverseVerticalCheckbox = NSButton(checkboxWithTitle: "垂直", target: nil, action: nil)
    private let reverseHorizontalCheckbox = NSButton(checkboxWithTitle: "水平", target: nil, action: nil)
    private let smoothCheckbox = NSButton(checkboxWithTitle: "平滑滚动", target: nil, action: nil)
    private let smoothVerticalCheckbox = NSButton(checkboxWithTitle: "垂直", target: nil, action: nil)
    private let smoothHorizontalCheckbox = NSButton(checkboxWithTitle: "水平", target: nil, action: nil)
    private let stepSlider = NSSlider(value: 33.6, minValue: 5, maxValue: 200, target: nil, action: nil)
    private let speedSlider = NSSlider(value: 2.7, minValue: 1, maxValue: 10, target: nil, action: nil)
    private let durationSlider = NSSlider(value: 4.35, minValue: 0, maxValue: 5, target: nil, action: nil)
    private let stepLabel = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")

    static func show(exceptionIndex: Int, window parent: NSWindow?) {
        if let active = activeController {
            active.window?.close()
            activeController = nil
        }
        let controller = ExceptionEditorController(exceptionIndex: exceptionIndex)
        activeController = controller
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(exceptionIndex: Int) {
        self.exceptionIndex = exceptionIndex
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "例外设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        refreshValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var currentException: AppException? {
        guard exceptionIndex < settings.exceptions.count else { return nil }
        return settings.exceptions[exceptionIndex]
    }

    private func buildInterface() {
        guard let window, let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = AppTheme.graphite.cgColor

        for checkbox in [inheritCheckbox, reverseCheckbox, reverseVerticalCheckbox, reverseHorizontalCheckbox, smoothCheckbox, smoothVerticalCheckbox, smoothHorizontalCheckbox] {
            checkbox.font = AppTheme.font(ofSize: 13)
            checkbox.target = self
            checkbox.action = #selector(anyCheckboxChanged)
        }

        for slider in [stepSlider, speedSlider, durationSlider] {
            slider.target = self
            slider.isContinuous = true
            slider.action = #selector(anySliderChanged)
        }

        func sliderRow(_ slider: NSSlider, _ label: NSTextField, title: String) -> NSView {
            let titleField = NSTextField(labelWithString: title)
            titleField.font = AppTheme.font(ofSize: 13, weight: .medium)
            titleField.textColor = AppTheme.primaryText
            label.font = AppTheme.font(ofSize: 12)
            label.textColor = AppTheme.secondaryText
            let stack = NSStackView(views: [titleField, slider, label])
            stack.orientation = .horizontal
            stack.spacing = 10
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
            return stack
        }

        let reverseRow = NSStackView(views: [reverseCheckbox, reverseVerticalCheckbox, reverseHorizontalCheckbox])
        reverseRow.orientation = .horizontal
        reverseRow.spacing = 12
        let smoothRow = NSStackView(views: [smoothCheckbox, smoothVerticalCheckbox, smoothHorizontalCheckbox])
        smoothRow.orientation = .horizontal
        smoothRow.spacing = 12

        let stack = NSStackView(views: [
            inheritCheckbox,
            NSStackView(views: []),
            reverseRow,
            smoothRow,
            sliderRow(stepSlider, stepLabel, title: "步长"),
            sliderRow(speedSlider, speedLabel, title: "速度"),
            sliderRow(durationSlider, durationLabel, title: "时长"),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
        ])
    }

    private func refreshValues() {
        guard let exception = currentException else { return }
        let granted = AXIsProcessTrusted()
        inheritCheckbox.state = exception.inherit ? .on : .off
        reverseCheckbox.state = granted && exception.reverse ? .on : .off
        reverseVerticalCheckbox.state = granted && exception.reverseVertical ? .on : .off
        reverseHorizontalCheckbox.state = granted && exception.reverseHorizontal ? .on : .off
        reverseCheckbox.isEnabled = granted
        reverseVerticalCheckbox.isEnabled = granted && exception.reverse
        reverseHorizontalCheckbox.isEnabled = granted && exception.reverse
        smoothCheckbox.state = granted && exception.smooth ? .on : .off
        smoothVerticalCheckbox.state = granted && exception.smoothVertical ? .on : .off
        smoothHorizontalCheckbox.state = granted && exception.smoothHorizontal ? .on : .off
        smoothCheckbox.isEnabled = granted
        smoothVerticalCheckbox.isEnabled = granted && exception.smooth
        smoothHorizontalCheckbox.isEnabled = granted && exception.smooth
        stepSlider.doubleValue = exception.step
        speedSlider.doubleValue = exception.speed
        durationSlider.doubleValue = exception.duration
        updateSliderLabels()
    }

    private func updateSliderLabels() {
        stepLabel.stringValue = String(format: "%.1f", stepSlider.doubleValue)
        speedLabel.stringValue = String(format: "%.2f×", speedSlider.doubleValue)
        durationLabel.stringValue = String(format: "%.2f", durationSlider.doubleValue)
    }

    @objc private func anyCheckboxChanged() {
        guard var exception = currentException else { return }
        let granted = AXIsProcessTrusted()
        exception.inherit = inheritCheckbox.state == .on
        if granted {
            exception.reverse = reverseCheckbox.state == .on
            exception.reverseVertical = reverseVerticalCheckbox.state == .on
            exception.reverseHorizontal = reverseHorizontalCheckbox.state == .on
            exception.smooth = smoothCheckbox.state == .on
            exception.smoothVertical = smoothVerticalCheckbox.state == .on
            exception.smoothHorizontal = smoothHorizontalCheckbox.state == .on
        }
        commit(exception)
    }

    @objc private func anySliderChanged() {
        guard var exception = currentException else { return }
        exception.step = stepSlider.doubleValue
        exception.speed = speedSlider.doubleValue
        exception.duration = durationSlider.doubleValue
        updateSliderLabels()
        commit(exception)
    }

    private func commit(_ exception: AppException) {
        guard exceptionIndex < settings.exceptions.count else { return }
        var list = settings.exceptions
        list[exceptionIndex] = exception
        settings.setExceptions(list)
    }
}
