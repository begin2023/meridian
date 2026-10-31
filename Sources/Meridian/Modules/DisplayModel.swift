import AppKit
import Combine
import DisplayLabKit

/// 显示器：所有硬件操作来自显示模块；本类负责状态发布、错误提示和退出还原。
@MainActor
final class DisplayModel: ObservableObject {
    @Published private(set) var displays: [ScreenDisplay] = []
    @Published private(set) var virtualScreens: [VirtualScreen] = []
    @Published private(set) var overrides: [String] = []
    @Published private(set) var busy: Set<CGDirectDisplayID> = []
    @Published private(set) var running = false
    @Published var message: String?

    @Published var smoothing = true
    @Published var smoothingMilliseconds = 300.0
    @Published var dimmingPoint = 0.25
    @Published var showVirtualScreens = false
    @Published var brightnessKeys = false
    /// 5K 渲染是否跟随显示器刷新率。默认固定 60Hz：5K 帧缓冲在高刷镜像下更容易出现闪屏。
    @Published var upsampleKeepsRefresh = false
    @Published private(set) var brightnessKeysActive = false
    /// 已打开 F1/F2 接管，但事件监听没有建立起来（通常是缺少系统权限）。
    @Published private(set) var brightnessKeysPermissionMissing = false
    @Published private(set) var brightnessHUDValues: [BrightnessHUDValue] = []
    var onBrightnessHUD: (([BrightnessHUDValue]) -> Void)?

    let engine: DisplayEngine

    init(suite: String) {
        engine = Suites.withSuite(suite) {
            let engine = DisplayEngine()
            _ = engine.smoothingEnabled
            return engine
        }
        engine.onChange = { [weak self] in self?.sync() }
        engine.onBrightnessKeysPermissionMissing = { [weak self] in
            guard let self else { return }
            self.brightnessKeysPermissionMissing = true
            self.brightnessKeysActive = false
        }
        engine.onBrightnessKeysAdjusted = { [weak self] values in
            self?.brightnessHUDValues = values
            self?.onBrightnessHUD?(values)
        }
        loadSettings()
    }

    func start() {
        guard !running else { return }
        running = true
        engine.start()
        refreshBrightnessKeysState()
        reloadOverrides()
        // 等显示器列表稳定后恢复上次的 5K 渲染选择
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restoreSavedUpsample() }
    }

    /// 退出或停用：撤销上采样、断开虚拟屏、恢复 gamma。
    func stop() {
        guard running else { return }
        engine.stop()
        running = false
        displays = []
        virtualScreens = []
    }

    private func sync() {
        displays = engine.displays
        virtualScreens = engine.virtualScreens
        refreshBrightnessKeysState()
    }

    private func refreshBrightnessKeysState() {
        brightnessKeysActive = engine.brightnessKeysActive
        brightnessKeysPermissionMissing = brightnessKeys && !brightnessKeysActive
    }

    func refreshBrightnessKeysStateForUI() {
        refreshBrightnessKeysState()
    }

    // MARK: 亮度

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        engine.setBrightness(value, for: id)
    }

    func setAllBrightness(_ value: Double) {
        for display in displays where display.brightnessBackend != .unavailable {
            engine.setBrightness(value, for: display.id)
        }
    }

    // MARK: 分辨率

    func apply(_ mode: DisplayModeInfo, to id: CGDirectDisplayID) {
        busy.insert(id)
        engine.applyMode(mode, to: id) { [weak self] error in
            self?.busy.remove(id)
            if let error { self?.message = "切换分辨率失败：\(error.localizedDescription)" }
        }
    }

    func restoreNative(_ id: CGDirectDisplayID) {
        if let display = displays.first(where: { $0.id == id }) { saveUpsample(.off, for: display) }
        busy.insert(id)
        engine.restoreNativeMode(for: id) { [weak self] error in
            self?.busy.remove(id)
            if let error { self?.message = "恢复原生分辨率失败：\(error.localizedDescription)" }
        }
    }

    func allModes(for id: CGDirectDisplayID) -> [DisplayModeInfo] { engine.allModes(for: id) }

    // MARK: HDR / 上采样 / 虚拟屏

    func setHDR(_ on: Bool, for id: CGDirectDisplayID) {
        busy.insert(id)
        engine.setHDR(on, for: id) { [weak self] ok in
            self?.busy.remove(id)
            if !ok { self?.message = "HDR 未能切换，可在“系统设置 › 显示器”中尝试。" }
        }
    }

    func setUpsample(_ mode: ScreenDisplay.Upsample, for id: CGDirectDisplayID) {
        busy.insert(id)
        defer { busy.remove(id) }
        let display = displays.first { $0.id == id }
        let refresh: Double? = upsampleKeepsRefresh ? nil : 60
        do {
            switch mode {
            case .off: try engine.disableUpsample()
            case .moreSpace: try engine.enableUpsample(for: id, hiDPI: false, refreshRate: refresh)
            case .hiDPI: try engine.enableUpsample(for: id, hiDPI: true, refreshRate: refresh)
            }
            message = nil
            if let display { saveUpsample(mode, for: display) }
        } catch {
            message = "5K 渲染开启失败：\(error.localizedDescription)（显示器未被改动）"
            NSLog("Meridian upsample failed: %@", error.localizedDescription)
            if let display { saveUpsample(.off, for: display) }
        }
    }

    /// 选择普通分辨率时调用：先撤销 5K 渲染再切换。
    func applyMode(_ mode: DisplayModeInfo, to display: ScreenDisplay) {
        if display.upsample != .off { saveUpsample(.off, for: display) }
        apply(mode, to: display.id)
    }

    private var store: UserDefaults { UserDefaults(suiteName: Suites.display) ?? .standard }

    private func upsampleKey(_ display: ScreenDisplay) -> String {
        "meridianUpsample.\(display.info.vendorID)-\(display.info.productID)"
    }

    private func saveUpsample(_ mode: ScreenDisplay.Upsample, for display: ScreenDisplay) {
        switch mode {
        case .off: store.removeObject(forKey: upsampleKey(display))
        case .moreSpace: store.set("moreSpace", forKey: upsampleKey(display))
        case .hiDPI: store.set("hiDPI", forKey: upsampleKey(display))
        }
        // 应用被杀掉时 UserDefaults 可能还没落盘，导致下次启动丢了 5K 选择。
        store.synchronize()
    }

    private func restoreSavedUpsample() {
        guard running else { return }
        for display in displays where display.upsample == .off && !display.isBuiltIn && !display.isOwnVirtual {
            switch store.string(forKey: upsampleKey(display)) {
            case "hiDPI": setUpsample(.hiDPI, for: display.id)
            case "moreSpace": setUpsample(.moreSpace, for: display.id)
            default: continue
            }
            return // 同一时间只支持一块屏上采样
        }
    }

    func createVirtual(_ spec: VirtualDisplayController.Spec) {
        do {
            try engine.createVirtualScreen(spec)
            message = nil
        } catch {
            message = "创建虚拟屏失败：\(error.localizedDescription)"
        }
        sync()
    }

    func disconnectVirtual(_ id: UUID) {
        engine.disconnectVirtualScreen(id)
        sync()
    }

    // MARK: HiDPI 覆盖

    var overrideHelperInstalled: Bool { engine.overrideHelperInstalled }

    func hasOverride(_ id: CGDirectDisplayID) -> Bool { engine.hasOverride(for: id, in: overrides) }

    func reloadOverrides() {
        guard engine.overrideHelperInstalled else { return }
        Task { [weak self] in
            guard let self else { return }
            let list = await self.engine.installedOverrides()
            self.overrides = list
        }
    }

    func toggleOverride(_ id: CGDirectDisplayID) {
        let installed = hasOverride(id)
        busy.insert(id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = installed
                    ? try await self.engine.removeHiDPIOverride(for: id)
                    : try await self.engine.installHiDPIOverride(for: id)
                self.message = text
            } catch {
                self.message = "HiDPI 覆盖失败：\(error.localizedDescription)"
            }
            self.busy.remove(id)
            self.reloadOverrides()
        }
    }

    // MARK: 设置

    private func loadSettings() {
        upsampleKeepsRefresh = store.bool(forKey: "meridianUpsampleNativeRefresh")
        smoothing = engine.smoothingEnabled
        smoothingMilliseconds = engine.smoothingDurationMilliseconds
        dimmingPoint = engine.combinedDimmingPoint
        showVirtualScreens = engine.showVirtualScreens
        brightnessKeys = engine.takeOverBrightnessKeys
    }

    func saveSettings() {
        store.set(upsampleKeepsRefresh, forKey: "meridianUpsampleNativeRefresh")
        store.synchronize()
        engine.smoothingEnabled = smoothing
        engine.smoothingDurationMilliseconds = smoothingMilliseconds
        engine.combinedDimmingPoint = dimmingPoint
        engine.showVirtualScreens = showVirtualScreens
        if engine.takeOverBrightnessKeys != brightnessKeys {
            engine.takeOverBrightnessKeys = brightnessKeys
        }
        refreshBrightnessKeysState()
        if brightnessKeys && !brightnessKeysActive {
            // 打开开关却没有建立事件监听：直接弹出系统授权提示，并在页面上给出明确说明。
            brightnessKeysPermissionMissing = true
            Permissions.request(.inputMonitoring)
            if !Permission.accessibility.granted {
                // 主动拦截并吞掉 F1/F2 的按键还需要辅助功能权限。
                Permissions.request(.accessibility)
            }
            message = "F1/F2 需要“输入监控”和“辅助功能”权限。请在提示或系统设置里授予，然后点“重新打开 Meridian”，再打开这个开关。"
        } else if brightnessKeysActive {
            brightnessKeysPermissionMissing = false
        }
    }
}

extension DisplayModeInfo {
    /// 例如“2560 × 1440 · 144Hz”。HiDPI 模式按桌面“看起来像”的尺寸显示（渲染像素的一半），
    /// 避免把 1280×720 的 HiDPI 误读成 2560×1440。
    var shortLabel: String {
        let rate = refreshRate > 0 ? " · \(Int(refreshRate.rounded()))Hz" : ""
        let width = isHiDPI ? pixelWidth / 2 : pixelWidth
        let height = isHiDPI ? pixelHeight / 2 : pixelHeight
        return "\(width) × \(height)\(isHiDPI ? " HiDPI" : "")\(rate)"
    }
}
