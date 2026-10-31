import AppKit
import DisplayCore

/// Builds the status menu: one submenu per display with resolution and
/// brightness controls, plus virtual screen and override sections as later
/// milestones land. The menu refreshes itself through NSMenuDelegate so
/// hot-plug and brightness-cache updates show up on the next open.
final class MenuBuilder: NSObject, NSMenuDelegate {
    weak var displayManager: DisplayManager?
    weak var appDelegate: AppDelegate?

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        populate(menu)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        let manager = displayManager
        let displays = manager?.displays ?? []

        if displays.isEmpty {
            let item = NSMenuItem(title: "未检测到显示器", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for display in displays {
            // Managed virtual screens stay hidden unless the preference turns
            // the virtual-screens section on — including the upsample master
            // screen while a mirror session is active.
            if display.isVirtual || (appDelegate?.virtualDisplayController.manages(displayID: display.identifier) ?? false),
               !AppSettings.shared.showVirtualScreens {
                continue
            }
            menu.addItem(makeDisplayMenuItem(for: display))
            menu.addItem(.separator())
        }

        if AppSettings.shared.showVirtualScreens {
            menu.addItem(makeVirtualScreensMenuItem())
            menu.addItem(.separator())
        }

        menu.addItem(makePreferencesItem())
        if appDelegate?.isEmbedded == false {
            menu.addItem(makeQuitItem())
        }
    }

    // MARK: - Display section

    private func makeDisplayMenuItem(for display: DisplayInfo) -> NSMenuItem {
        let submenu = NSMenu()

        let header = NSMenuItem(
            title: "\(display.name) — \(display.pixelWidth)×\(display.pixelHeight)（\(Int(display.scale * 100))%）",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        submenu.addItem(header)
        submenu.addItem(.separator())

        submenu.addItem(makeHDRMenuItem(for: display))
        if !display.isBuiltIn, !display.isVirtual {
            submenu.addItem(makeUpsampleMenuItem(for: display))
        }
        submenu.addItem(makeResolutionMenuItem(for: display))
        submenu.addItem(makeBrightnessMenuItem(for: display))
        if !display.isBuiltIn, !display.isVirtual {
            submenu.addItem(makeOverrideMenuItem(for: display))
        }

        let item = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func makeOverrideMenuItem(for display: DisplayInfo) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let hint = NSMenuItem(title: "写入系统级 HiDPI 模式表（需管理员授权）", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        submenu.addItem(hint)

        let installItem = NSMenuItem(
            title: "  启用 HiDPI 覆盖…",
            action: #selector(AppDelegate.enableDisplayOverride(_:)),
            keyEquivalent: ""
        )
        installItem.target = appDelegate
        installItem.representedObject = display.identifier
        submenu.addItem(installItem)

        let removeItem = NSMenuItem(
            title: "  移除 HiDPI 覆盖",
            action: #selector(AppDelegate.removeDisplayOverride(_:)),
            keyEquivalent: ""
        )
        removeItem.target = appDelegate
        removeItem.representedObject = display.identifier
        submenu.addItem(removeItem)

        let note = NSMenuItem(title: "  安装后需重插显示线或注销重登", action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)

        let item = NSMenuItem(title: "显示器覆盖", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func makeHDRMenuItem(for display: DisplayInfo) -> NSMenuItem {
        guard HDRService.isAvailable, HDRService.supportsHDR(display.identifier) else {
            let item = NSMenuItem(title: "HDR（此显示器不支持）", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        // The EDID verdict beats SkyLight's optimistic supportsHDR: a panel
        // whose CTA-861 block lacks PQ/HLG cannot show HDR10 content, so the
        // macOS-level toggle would flip state with no visible change.
        if let hdr = EDIDCapability.hdrInfo(for: display.identifier), !hdr.pqSupported, !hdr.hlgSupported {
            let item = NSMenuItem(title: "HDR（面板无 PQ/HLG 能力，切换无可见效果）", action: nil, keyEquivalent: "")
            item.isEnabled = false
            if let luminance = hdr.maxLuminanceCDm2 {
                item.toolTip = "面板 EDID 仅声明 SDR gamma，未声明 HDR10 传输函数，声明的最大亮度约 \(luminance) 尼特（SDR 水平）。"
            } else {
                item.toolTip = "面板 EDID 仅声明 SDR gamma，未声明 HDR10/HLG 传输函数。"
            }
            return item
        }
        let enabled = HDRService.isEnabled(display.identifier) ?? false
        let item = NSMenuItem(
            title: "HDR",
            action: #selector(AppDelegate.toggleHDR(_:)),
            keyEquivalent: ""
        )
        item.target = appDelegate
        item.state = enabled ? .on : .off
        item.representedObject = display.identifier
        item.toolTip = "在系统级 HDR 模式间切换；若点击后未生效，请用系统设置 → 显示器 → HDR 调整。"
        return item
    }

    /// Software HiDPI upsample: creates a 2× virtual screen and mirrors the
    /// panel to it, rendering at 5K before downsampling to the physical
    /// display. Effective without reconnecting. Two flavours: a
    /// LoDPI master (the classic "more space" 5K desktop) and a HiDPI master
    /// (same layout as native, 2× rendered downsample).
    private func makeUpsampleMenuItem(for display: DisplayInfo) -> NSMenuItem {
        let session = appDelegate?.virtualDisplayController.activeMirrorSession
        if let session {
            if session.physicalDisplayID == display.identifier {
                let item = NSMenuItem(
                    title: "关闭上采样（恢复原生显示）",
                    action: #selector(AppDelegate.disableUpsample(_:)),
                    keyEquivalent: ""
                )
                item.target = appDelegate
                item.state = .on
                item.toolTip = "取消 \(session.spec.pixelWidth)×\(session.spec.pixelHeight)\(session.spec.hiDPI ? " HiDPI" : "") 虚拟屏镜像，面板回到原生分辨率。退出 DisplayLab 也会自动还原。"
                return item
            }
            let item = NSMenuItem(title: "上采样已用于另一台显示器", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        // Native pixel size from the CoreDisplay dictionary; the current mode
        // may be a scaled one, which would produce a misleading 2× target.
        let info = CoreDisplayBridge.createInfoDictionary(for: display.identifier)
        let nativeWidth = info?["kCGDisplayPixelWidth"] as? Int ?? display.pixelWidth
        let nativeHeight = info?["kCGDisplayPixelHeight"] as? Int ?? display.pixelHeight

        let moreSpaceItem = NSMenuItem(
            title: "开启 \(nativeWidth * 2)×\(nativeHeight * 2) 上采样（更多空间）",
            action: #selector(AppDelegate.enableUpsample(_:)),
            keyEquivalent: ""
        )
        moreSpaceItem.target = appDelegate
        moreSpaceItem.representedObject = UpsampleSelection(displayIdentifier: display.identifier, hiDPI: false)
        moreSpaceItem.toolTip = "桌面变成 \(nativeWidth * 2)×\(nativeHeight * 2) 逻辑像素（4 倍工作区，UI 明显变小），系统把 5K 画面实时缩到面板显示。此模式通过虚拟屏镜像实现软件上采样。注意：切换后个别应用的状态栏图标可能显示异常，重启对应应用即恢复。"

        let hidpiItem = NSMenuItem(
            title: "开启 \(nativeWidth * 2)×\(nativeHeight * 2) 上采样（HiDPI 渲染）",
            action: #selector(AppDelegate.enableUpsample(_:)),
            keyEquivalent: ""
        )
        hidpiItem.target = appDelegate
        hidpiItem.representedObject = UpsampleSelection(displayIdentifier: display.identifier, hiDPI: true)
        hidpiItem.toolTip = "桌面布局和原生一样大，但按 2× 渲染再缩到面板，窗口文字更细腻。视觉变化较微妙。"

        let item = NSMenuItem(title: "上采样", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(moreSpaceItem)
        submenu.addItem(hidpiItem)
        item.submenu = submenu
        return item
    }

    private func makeResolutionMenuItem(for display: DisplayInfo) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let restoreItem = NSMenuItem(
            title: "恢复原生分辨率（最高刷新率）",
            action: #selector(AppDelegate.restoreNativeMode(_:)),
            keyEquivalent: ""
        )
        restoreItem.target = appDelegate
        restoreItem.representedObject = display.identifier
        restoreItem.toolTip = "切回面板原生分辨率。注意：切换渲染缩放后，个别应用的状态栏图标可能显示异常（macOS 的已知表现，与切换来源无关），重启对应应用即恢复。"
        submenu.addItem(restoreItem)
        submenu.addItem(.separator())

        let modes = Self.usableModes(for: display)
        if modes.isEmpty {
            let item = NSMenuItem(title: "无可用模式", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }

        for mode in modes {
            let state: NSControl.StateValue = mode.isCurrent ? .on : .off
            let item = NSMenuItem(title: mode.label, action: #selector(AppDelegate.switchMode(_:)), keyEquivalent: "")
            item.target = appDelegate
            item.state = state
            item.representedObject = ModeSelection(displayIdentifier: display.identifier, mode: mode)
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Curated mode list for the menu. The full table contains entries that
    /// are no-ops on a given panel (e.g. 4K timings on a 1440p screen — the
    /// monitor internally downscales them to an identical picture), aspect
    /// mismatches (4:3 modes on a 16:9 panel) and duplicate refresh variants;
    /// all hide here. Kept: current mode, every refresh of the native
    /// resolution, and the standard 16:9-ish HiDPI desktops (0.75× / 0.625× /
    /// 0.5×).
    private static func usableModes(for display: DisplayInfo) -> [DisplayModeInfo] {
        let info = CoreDisplayBridge.createInfoDictionary(for: display.identifier)
        let nativeWidth = info?["kCGDisplayPixelWidth"] as? Int ?? display.pixelWidth
        let nativeHeight = info?["kCGDisplayPixelHeight"] as? Int ?? display.pixelHeight
        guard nativeWidth > 0, nativeHeight > 0 else { return display.sortedModes }

        let nativeAspect = Double(nativeWidth) / Double(nativeHeight)
        let standardSteps: Set<Double> = [0.5, 0.625, 0.75]
        var seenLabels = Set<String>()
        var result: [DisplayModeInfo] = []
        for mode in display.sortedModes {
            if !mode.isCurrent {
                let matchesNative = mode.pixelWidth == nativeWidth && mode.pixelHeight == nativeHeight
                let step = Double(mode.pixelWidth) / Double(nativeWidth)
                let modeAspect = Double(mode.pixelWidth) / Double(mode.pixelHeight)
                let aspectMatches = abs(modeAspect - nativeAspect) / nativeAspect < 0.02
                let isStandardStep = mode.isHiDPI
                    && mode.pixelWidth < nativeWidth
                    && mode.pixelHeight < nativeHeight
                    && standardSteps.contains(step)
                guard matchesNative || (aspectMatches && isStandardStep) else { continue }
            }
            // CGS and public enumeration can surface the same timing twice
            // (119.98 Hz vs 120 Hz read as one label); show it once.
            guard seenLabels.insert(mode.label).inserted else { continue }
            result.append(mode)
        }
        return result
    }

    private func makeBrightnessMenuItem(for display: DisplayInfo) -> NSMenuItem {
        let manager = displayManager
        guard let controller = manager?.brightnessController(for: display.identifier) else {
            let item = NSMenuItem(title: "亮度（此显示器不支持调节）", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        let row = BrightnessSliderRow(
            displayIdentifier: display.identifier,
            fraction: manager?.cachedBrightness(for: display.identifier) ?? 1.0,
            target: appDelegate,
            action: #selector(AppDelegate.brightnessSliderChanged(_:))
        )

        let item = NSMenuItem(title: "亮度", action: nil, keyEquivalent: "")
        item.view = row
        item.isEnabled = controller.backendKind != .unavailable
        return item
    }

    // MARK: - Virtual screens

    private func makeVirtualScreensMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let createItem = NSMenuItem(title: "创建虚拟屏幕", action: nil, keyEquivalent: "")
        createItem.isEnabled = false
        submenu.addItem(createItem)

        for spec in VirtualDisplayController.Spec.presets {
            let item = NSMenuItem(
                title: "  \(spec.name)（\(spec.pixelWidth)×\(spec.pixelHeight) HiDPI）",
                action: #selector(AppDelegate.createVirtualScreen(_:)),
                keyEquivalent: ""
            )
            item.target = appDelegate
            item.representedObject = spec
            submenu.addItem(item)
        }

        let active = appDelegate?.virtualDisplayController.activeSpecs ?? []
        if !active.isEmpty {
            submenu.addItem(.separator())
            let connectedItem = NSMenuItem(title: "已连接", action: nil, keyEquivalent: "")
            connectedItem.isEnabled = false
            submenu.addItem(connectedItem)

            for (id, spec) in active {
                let item = NSMenuItem(
                    title: "  断开 \(spec.name)（\(spec.pixelWidth)×\(spec.pixelHeight)）",
                    action: #selector(AppDelegate.disconnectVirtualScreen(_:)),
                    keyEquivalent: ""
                )
                item.target = appDelegate
                item.representedObject = id
                submenu.addItem(item)
            }

            let disconnectAllItem = NSMenuItem(
                title: "  全部断开",
                action: #selector(AppDelegate.disconnectAllVirtualScreens),
                keyEquivalent: ""
            )
            disconnectAllItem.target = appDelegate
            submenu.addItem(disconnectAllItem)
        }

        let item = NSMenuItem(title: "虚拟屏幕", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    // MARK: - Common items

    private func makePreferencesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "偏好设置…", action: #selector(AppDelegate.showPreferences), keyEquivalent: ",")
        item.target = appDelegate
        return item
    }

    private func makeQuitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "退出 DisplayLab", action: #selector(AppDelegate.quitApplication), keyEquivalent: "q")
        item.target = appDelegate
        return item
    }
}

/// Slider row shown inside the brightness menu item: label, slider and a
/// live percentage, styled with the app's dark HUD palette.
final class BrightnessSliderRow: NSView {
    let displayIdentifier: CGDirectDisplayID
    private let slider: NSSlider
    private let valueLabel: NSTextField

    init(displayIdentifier: CGDirectDisplayID, fraction: Double, target: AnyObject?, action: Selector) {
        self.displayIdentifier = displayIdentifier

        slider = NSSlider(value: fraction * 100, minValue: 0, maxValue: 100, target: target, action: action)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.focusRingType = .none
        slider.translatesAutoresizingMaskIntoConstraints = false

        valueLabel = NSTextField(labelWithString: "\(Int(round(fraction * 100)))%")
        valueLabel.font = AppTheme.font(ofSize: 11, weight: .medium)
        valueLabel.textColor = AppTheme.secondaryText
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 28))

        let titleLabel = NSTextField(labelWithString: "亮度")
        titleLabel.font = AppTheme.font(ofSize: 12, weight: .medium)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(slider)
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 260),
            heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.widthAnchor.constraint(equalToConstant: 38),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentFraction: Double {
        slider.doubleValue / 100
    }

    func refreshValueLabel() {
        valueLabel.stringValue = "\(Int(round(slider.doubleValue)))%"
    }
}

/// Menu item payload identifying a display mode choice.
struct ModeSelection {
    let displayIdentifier: CGDirectDisplayID
    let mode: DisplayModeInfo
}

/// Menu item payload for the upsample toggle: which panel and which master
/// screen flavour (LoDPI "more space" vs HiDPI rendered).
struct UpsampleSelection {
    let displayIdentifier: CGDirectDisplayID
    let hiDPI: Bool
}
