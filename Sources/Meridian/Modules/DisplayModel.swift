import AppKit
import Combine
import DisplayLabKit

/// 显示器：所有硬件操作来自显示模块；本类负责状态发布、错误提示和退出还原。
@MainActor
final class DisplayModel: ObservableObject {
    @Published private(set) var displays: [ScreenDisplay] = []
    @Published private(set) var virtualScreens: [VirtualScreen] = []
    @Published private(set) var busy: Set<CGDirectDisplayID> = []
    @Published private(set) var running = false
    @Published var message: String?

    @Published var smoothing = true
    @Published var smoothingMilliseconds = 300.0
    @Published var dimmingPoint = 0.25
    @Published var showVirtualScreens = false
    @Published var brightnessKeys = false
    /// 外接屏进入 HDR 时关闭夜览和原彩显示。
    @Published var hdrDisablesNightShift = false
    /// 新建虚拟屏时使用 HDR（PQ）。
    @Published var virtualHDR = false
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
    }

    /// 退出或停用：断开虚拟屏、恢复 gamma 与亮度提升。
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

    /// HDR 模式下亮度提升到 100% 以上（倍数，1 为关闭）。
    func setBoost(_ factor: Double, for id: CGDirectDisplayID) {
        engine.setBoost(factor, for: id)
    }

    // MARK: 分辨率与刷新率

    func apply(_ mode: DisplayModeInfo, to id: CGDirectDisplayID) {
        busy.insert(id)
        engine.applyMode(mode, to: id) { [weak self] error in
            self?.busy.remove(id)
            if let error { self?.message = "切换分辨率失败：\(error.localizedDescription)" }
        }
    }

    func applyResolution(_ option: ResolutionOption, to id: CGDirectDisplayID) {
        busy.insert(id)
        engine.applyResolution(option, to: id) { [weak self] error in
            self?.busy.remove(id)
            if let error { self?.message = "切换分辨率失败：\(error.localizedDescription)" }
        }
    }

    func setHiDPI(_ on: Bool, for id: CGDirectDisplayID) {
        busy.insert(id)
        engine.setHiDPI(on, for: id) { [weak self] error in
            self?.busy.remove(id)
            if let error { self?.message = "切换 HiDPI 失败：\(error.localizedDescription)" }
        }
    }

    func applyRefreshRate(_ rate: Double, to id: CGDirectDisplayID) {
        busy.insert(id)
        engine.applyRefreshRate(rate, to: id) { [weak self] error in
            self?.busy.remove(id)
            if let error { self?.message = "切换刷新率失败：\(error.localizedDescription)" }
        }
    }

    func restoreNative(_ id: CGDirectDisplayID) {
        busy.insert(id)
        engine.restoreNativeMode(for: id) { [weak self] error in
            self?.busy.remove(id)
            if let error { self?.message = "恢复原生分辨率失败：\(error.localizedDescription)" }
        }
    }

    // MARK: HDR / 虚拟屏

    func setHDR(_ on: Bool, for id: CGDirectDisplayID) {
        busy.insert(id)
        engine.setHDR(on, for: id) { [weak self] ok in
            self?.busy.remove(id)
            if !ok { self?.message = "HDR 未能切换，可在“系统设置 › 显示器”中尝试。" }
        }
    }

    private var store: UserDefaults { UserDefaults(suiteName: Suites.display) ?? .standard }

    func createVirtual(_ spec: VirtualDisplayController.Spec) {
        do {
            try engine.createVirtualScreen(spec.withHDR(virtualHDR))
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

    // MARK: HiDPI 档位

    /// 写入（或更新）这台显示器的 HiDPI 档位；第一次会弹出管理员授权安装助手。
    func installHiDPIOverride(_ id: CGDirectDisplayID) {
        runOverride(id) { try await $0.installHiDPIOverride(for: id) }
    }

    func removeHiDPIOverride(_ id: CGDirectDisplayID) {
        runOverride(id) { try await $0.removeHiDPIOverride(for: id) }
    }

    private func runOverride(_ id: CGDirectDisplayID, _ body: @escaping (DisplayEngine) async throws -> String) {
        busy.insert(id)
        Task { [weak self] in
            guard let self else { return }
            do {
                self.message = try await body(self.engine)
            } catch {
                self.message = "HiDPI 档位操作失败：\(error.localizedDescription)"
            }
            self.busy.remove(id)
        }
    }

    // MARK: 设置

    private func loadSettings() {
        // 旧版“5K 渲染”用虚拟屏镜像实现，启动时会自动重建；现在改用原生 HiDPI 档位，清掉遗留选择。
        for key in store.dictionaryRepresentation().keys
        where key.hasPrefix("meridianUpsample") {
            store.removeObject(forKey: key)
        }
        virtualHDR = store.bool(forKey: "meridianVirtualHDR")
        hdrDisablesNightShift = engine.hdrDisablesNightShift
        smoothing = engine.smoothingEnabled
        smoothingMilliseconds = engine.smoothingDurationMilliseconds
        dimmingPoint = engine.combinedDimmingPoint
        showVirtualScreens = engine.showVirtualScreens
        brightnessKeys = engine.takeOverBrightnessKeys
    }

    func saveSettings() {
        store.set(virtualHDR, forKey: "meridianVirtualHDR")
        if engine.hdrDisablesNightShift != hdrDisablesNightShift {
            engine.hdrDisablesNightShift = hdrDisablesNightShift
        }
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

extension ResolutionOption {
    /// 桌面“看起来像”的尺寸，例如“2560 × 1440”。
    var sizeLabel: String { "\(width) × \(height)" }
    /// 全部模式列表里区分 HiDPI 与普通模式。
    var fullLabel: String { sizeLabel + (hiDPI ? " · HiDPI" : " · 普通") }
}

extension ScreenDisplay {
    /// 例如“2560 × 1440 · 144Hz”；HiDPI 状态单独用标签显示。
    var modeSummary: String {
        guard let resolution = currentResolution else { return "" }
        let rate = resolution.currentRefreshRate.map { " · \(Int($0.rounded()))Hz" } ?? ""
        return resolution.sizeLabel + rate
    }

    func isNativeSize(_ option: ResolutionOption) -> Bool {
        option.width == nativeWidth && option.height == nativeHeight
    }
}

/// 刷新率显示：整数显示为“144 Hz”，NTSC 之类保留两位小数。
func refreshLabel(_ rate: Double) -> String {
    abs(rate - rate.rounded()) < 0.05 ? "\(Int(rate.rounded())) Hz" : String(format: "%.2f Hz", rate)
}
