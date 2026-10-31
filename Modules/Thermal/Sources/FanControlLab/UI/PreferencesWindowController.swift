import AppKit
import ServiceManagement

/// 设置窗口：监控间隔、温度单位、菜单栏显示、开机自启、温控曲线。即时保存；
/// 曲线阈值支持拖滑块或直接键入，点"应用到风扇"立即以当前曲线生效为策略。
final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    private let settings = AppSettings.shared
    private let readOnly: Bool

    /// 曲线区控件（滑块与输入框双向联动，需实例级访问）
    private var increaseSlider: ClosureSlider?
    private var maxSlider: ClosureSlider?
    private var increaseField: NSTextField?
    private var maxField: NSTextField?
    private var previewLabel: NSTextField?

    /// "应用到风扇"回调（AppDelegate 接线：安装引导 + 应用曲线策略），返回是否成功。
    var applyCurveHandler: (() -> Bool)?

    init(readOnly: Bool = true) {
        self.readOnly = readOnly
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 424),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 界面

    private func buildContent() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 424))

        var y: CGFloat = 378

        func addLabel(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = AppTheme.font(ofSize: 13)
            label.textColor = AppTheme.primaryText
            label.frame = NSRect(x: 24, y: y, width: 120, height: 20)
            container.addSubview(label)
        }

        // 监控间隔
        addLabel("刷新间隔：")
        let intervalPopup = NSPopUpButton(frame: NSRect(x: 150, y: y - 4, width: 120, height: 26))
        for (title, _) in Self.intervalChoices {
            intervalPopup.addItem(withTitle: title)
        }
        if let index = Self.intervalChoices.firstIndex(where: { $0.1 == settings.refreshInterval }) {
            intervalPopup.selectItem(at: index)
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged(_:))
        container.addSubview(intervalPopup)
        y -= 40

        // 温度单位
        addLabel("温度单位：")
        let unitPopup = NSPopUpButton(frame: NSRect(x: 150, y: y - 4, width: 120, height: 26))
        unitPopup.addItems(withTitles: ["摄氏度 (°C)", "华氏度 (°F)"])
        unitPopup.selectItem(at: settings.usesFahrenheit ? 1 : 0)
        unitPopup.target = self
        unitPopup.action = #selector(unitChanged(_:))
        container.addSubview(unitPopup)
        y -= 40

        // 菜单栏显示温度
        addLabel("菜单栏温度：")
        let tempPopup = NSPopUpButton(frame: NSRect(x: 150, y: y - 4, width: 120, height: 26))
        tempPopup.addItems(withTitles: ["只显示转速", "转速 + CPU 温度"])
        tempPopup.selectItem(at: settings.menuBarShowsTemperature ? 1 : 0)
        tempPopup.target = self
        tempPopup.action = #selector(menuBarChanged(_:))
        container.addSubview(tempPopup)
        y -= 40

        // 最大转速上限
        addLabel("最大转速上限：")
        let capPopup = NSPopUpButton(frame: NSRect(x: 150, y: y - 4, width: 120, height: 26))
        let capChoices: [(String, Double)] = [
            ("80%", 0.8), ("85%", 0.85), ("90%", 0.9), ("95%", 0.95), ("100%", 1.0),
        ]
        for (title, _) in capChoices {
            capPopup.addItem(withTitle: title)
        }
        let capIndex = capChoices.firstIndex(where: { abs($0.1 - settings.maximumRPMFraction) < 0.001 }) ?? 2
        capPopup.selectItem(at: capIndex)
        capPopup.target = self
        capPopup.action = #selector(capChanged(_:))
        objc_setAssociatedObject(capPopup, &Self.capKey, capChoices, .OBJC_ASSOCIATION_RETAIN)
        container.addSubview(capPopup)
        y -= 40

        // 开机自启由统一 Shell 管理；本地开发窗口不注册登录项。
        let loginLabel = NSTextField(labelWithString: "登录启动：由统一 Shell 管理")
        loginLabel.font = AppTheme.font(ofSize: 12)
        loginLabel.textColor = AppTheme.secondaryText
        loginLabel.frame = NSRect(x: 24, y: y, width: 260, height: 20)
        container.addSubview(loginLabel)
        y -= 44

        // 温控曲线（"基于温度"模式的默认阈值，可在每风扇对话框覆盖）
        let curveHeader = NSTextField(labelWithString: "温控曲线：")
        curveHeader.font = AppTheme.font(ofSize: 13, weight: .semibold)
        curveHeader.textColor = AppTheme.primaryText
        curveHeader.frame = NSRect(x: 24, y: y, width: 160, height: 20)
        container.addSubview(curveHeader)
        y -= 30

        addLabel("开始提速温度：")
        let increaseSlider = ClosureSlider(value: settings.defaultIncreaseAt, minValue: 40, maxValue: 90)
        increaseSlider.frame = NSRect(x: 150, y: y - 4, width: 150, height: 24)
        let increaseField = Self.temperatureField(value: settings.formattedTemperature(settings.defaultIncreaseAt))
        increaseField.frame = NSRect(x: 306, y: y, width: 60, height: 20)
        increaseField.target = self
        increaseField.action = #selector(temperatureFieldSubmitted(_:))
        increaseField.delegate = self
        container.addSubview(increaseSlider)
        container.addSubview(increaseField)
        self.increaseSlider = increaseSlider
        self.increaseField = increaseField
        y -= 32

        addLabel("满载温度：")
        let maxSlider = ClosureSlider(value: settings.defaultMaxAt, minValue: 60, maxValue: 105)
        maxSlider.frame = NSRect(x: 150, y: y - 4, width: 150, height: 24)
        let maxField = Self.temperatureField(value: settings.formattedTemperature(settings.defaultMaxAt))
        maxField.frame = NSRect(x: 306, y: y, width: 60, height: 20)
        maxField.target = self
        maxField.action = #selector(temperatureFieldSubmitted(_:))
        maxField.delegate = self
        container.addSubview(maxSlider)
        container.addSubview(maxField)
        self.maxSlider = maxSlider
        self.maxField = maxField
        y -= 30

        // 演算预览：按第一风扇的最低/最高转速计算中间温度对应转速
        let preview = NSTextField(labelWithString: Self.curvePreview(increaseAt: settings.defaultIncreaseAt,
                                                                     maxAt: settings.defaultMaxAt))
        preview.font = AppTheme.font(ofSize: 10.5)
        preview.textColor = AppTheme.secondaryText
        preview.frame = NSRect(x: 24, y: y - 4, width: 340, height: 32)
        preview.lineBreakMode = .byWordWrapping
        preview.maximumNumberOfLines = 2
        container.addSubview(preview)
        self.previewLabel = preview

        if readOnly {
            let hint = NSTextField(labelWithString: "当前为只读监控；风扇写入与特权助手的安装均已禁用。")
            hint.font = AppTheme.font(ofSize: 11)
            hint.textColor = AppTheme.secondaryText
            hint.frame = NSRect(x: 24, y: 36, width: 332, height: 22)
            container.addSubview(hint)
        } else {
            // 应用按钮：把当前曲线立即设为风扇策略（免去再去菜单点一次）
            let hint = NSTextField(labelWithString: "将当前曲线应用到所有风扇：")
            hint.font = AppTheme.font(ofSize: 12)
            hint.textColor = AppTheme.secondaryText
            hint.frame = NSRect(x: 24, y: 40, width: 220, height: 18)
            container.addSubview(hint)
            let applyButton = NSButton(title: "应用到风扇", target: self, action: #selector(applyCurveClicked(_:)))
            applyButton.bezelStyle = .rounded
            applyButton.font = AppTheme.font(ofSize: 12)
            applyButton.frame = NSRect(x: 262, y: 32, width: 94, height: 28)
            container.addSubview(applyButton)
        }

        increaseSlider.handler = { [weak self] in self?.syncCurve() }
        maxSlider.handler = { [weak self] in self?.syncCurve() }

        return container
    }

    private static func temperatureField(value: String) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 20))
        field.stringValue = value
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.font = AppTheme.font(ofSize: 12, weight: .medium)
        field.alignment = NSTextAlignment.center
        return field
    }

    /// 滑块/输入框任一变化：同步设置、另一侧显示与预览，并广播刷新。
    private func syncCurve() {
        guard let increaseSlider, let maxSlider, let increaseField, let maxField, let previewLabel else { return }
        // 满载温度至少比开始提速高 5 度
        if maxSlider.doubleValue < increaseSlider.doubleValue + 5 {
            maxSlider.doubleValue = increaseSlider.doubleValue + 5
        }
        settings.defaultIncreaseAt = increaseSlider.doubleValue
        settings.defaultMaxAt = maxSlider.doubleValue
        Self.setTemperatureText(increaseField, value: increaseSlider.doubleValue)
        Self.setTemperatureText(maxField, value: maxSlider.doubleValue)
        previewLabel.stringValue = Self.curvePreview(increaseAt: settings.defaultIncreaseAt,
                                                     maxAt: settings.defaultMaxAt)
        NotificationCenter.default.post(name: .fanControlSettingsChanged, object: nil)
    }

    /// 输入框实时跟随滑块。点击过的输入框 field editor 会驻留（点滑块也不结束编辑），
    /// 此时 stringValue 写不进显示——必须写编辑器本身；否则旧文本会在编辑结束
    /// 时反过来覆盖拖动结果。两种写法都能实时跟随，且不触发 end-editing 事件。
    private static func setTemperatureText(_ field: NSTextField, value: Double) {
        let text = AppSettings.shared.formattedTemperature(value)
        if let editor = field.currentEditor() {
            editor.string = text
        } else {
            field.stringValue = text
        }
    }

    /// 从输入文本解析温度（剥离 °C/°F 等非数字字符；华氏换回摄氏），越界夹取。
    private func parsedTemperature(from text: String, sliderMin: Double, sliderMax: Double) -> Double? {
        let cleaned = text.filter { "0123456789.-".contains($0) }
        guard let value = Double(cleaned) else { return nil }
        let celsius = settings.usesFahrenheit ? (value - 32) * 5 / 9 : value
        return min(max(celsius, sliderMin), sliderMax)
    }

    private func commitTemperatureField(_ field: NSTextField) {
        let isIncrease = field === increaseField
        guard let slider = isIncrease ? increaseSlider : maxSlider else { return }
        guard let value = parsedTemperature(
            from: field.stringValue,
            sliderMin: isIncrease ? 40 : 60,
            sliderMax: isIncrease ? 90 : 105
        ) else {
            syncCurve() // 非法输入：还原为当前值
            return
        }
        if abs(slider.doubleValue - value) < 0.5 {
            // 未变化：仅归一化显示（如补上单位），不再广播
            Self.setTemperatureText(field, value: slider.doubleValue)
            return
        }
        slider.doubleValue = value
        syncCurve()
    }

    /// 按等分温度点演算对应转速（使用当前已知的风扇最低/最高转速；
    /// 传原始上限，封顶由 targetRPM 内部的 effectiveMaximumRPM 统一处理）。
    private static func curvePreview(increaseAt: Double, maxAt: Double) -> String {
        let minimum = AppSettings.shared.knownMinimumRPM ?? 1000
        let maximum = AppSettings.shared.knownMaximumRPM ?? 4900
        var points: [String] = []
        let steps = 4
        for step in 0...steps {
            let temperature = increaseAt + (maxAt - increaseAt) * Double(step) / Double(steps)
            let target = FanSpeedCalculator.targetRPM(
                mode: .sensor(sensorID: "", increaseAt: increaseAt, maxAt: maxAt),
                sensorValue: temperature,
                fan: FanSnapshot(index: 0, name: "", minimumRPM: minimum, currentRPM: minimum,
                                 maximumRPM: maximum, targetRPM: minimum, modeByte: 0)
            ) ?? minimum
            points.append(String(format: "%.0f°C→%.0f", temperature, target))
        }
        return points.joined(separator: "　")
    }

    private static var capKey: UInt8 = 0

    @objc private func capChanged(_ sender: NSPopUpButton) {
        guard let choices = objc_getAssociatedObject(sender, &Self.capKey) as? [(String, Double)],
              choices.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        settings.maximumRPMFraction = choices[sender.indexOfSelectedItem].1
        NotificationCenter.default.post(name: .fanControlSettingsChanged, object: nil)
    }

    /// 刷新间隔选项（索引与弹出菜单条目一一对应）。
    private static let intervalChoices: [(String, TimeInterval)] = [
        ("1 秒", 1.0), ("1.5 秒", 1.5), ("2 秒", 2.0), ("3 秒", 3.0), ("5 秒", 5.0),
    ]

    // MARK: - 动作

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.intervalChoices.indices.contains(index) else { return }
        settings.refreshInterval = Self.intervalChoices[index].1
        NotificationCenter.default.post(name: .fanControlSettingsChanged, object: nil)
    }

    @objc private func unitChanged(_ sender: NSPopUpButton) {
        settings.usesFahrenheit = sender.indexOfSelectedItem == 1
        syncCurve() // 同步刷新输入框/预览的单位显示（并广播设置变更）
    }

    @objc private func menuBarChanged(_ sender: NSPopUpButton) {
        settings.menuBarShowsTemperature = sender.indexOfSelectedItem == 1
        NotificationCenter.default.post(name: .fanControlSettingsChanged, object: nil)
    }

    // MARK: - 温度输入框（NSTextFieldDelegate）

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field === increaseField || field === maxField else { return }
        commitTemperatureField(field)
    }

    @objc private func temperatureFieldSubmitted(_ sender: NSTextField) {
        commitTemperatureField(sender)
    }

    // MARK: - 应用按钮

    @objc private func applyCurveClicked(_ sender: NSButton) {
        guard !readOnly else { return }
        guard applyCurveHandler?() == true else { return }
        let original = sender.title
        sender.title = "已应用 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.title = original
        }
    }

    @objc private func loginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
        } catch {
            sender.state = settings.launchAtLogin ? .on : .off
            let alert = NSAlert()
            alert.messageText = "无法修改开机自启"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension Notification.Name {
    static let fanControlSettingsChanged = Notification.Name("fanControlSettingsChanged")
}
