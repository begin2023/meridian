import AppKit
import CoreGraphics
@_exported import DisplayCore

/// 供宿主进程内直接使用的类型化接口：亮度、分辨率与刷新率、HDR、虚拟屏与 HiDPI 档位。
///
/// 所有方法在主线程调用；耗时的硬件操作内部转到后台队列，结果在主线程回调。
public struct ScreenDisplay: Identifiable, Equatable {
    public enum BrightnessBackend: String, Sendable {
        /// hdrSDR：外接屏处于 HDR 模式，亮度走 macOS 的 SDR 亮度（控制中心里的 HDR 亮度滑块）。
        case ddc, apple, gammaOnly, hdrSDR, unavailable
    }

    public enum HiDPIOverrideState: Equatable, Sendable {
        /// 没有覆盖文件。
        case none
        /// 已写入当前这一套 HiDPI 档位。
        case upToDate
        /// 有覆盖文件，但档位比当前这一套少（旧版只写了 2 档）。
        case outdated
    }

    public var id: CGDirectDisplayID { info.identifier }
    public let info: DisplayInfo
    /// 面板原生像素。
    public let nativeWidth: Int
    public let nativeHeight: Int
    /// 精选分辨率：与面板同宽高比的 HiDPI 档（大到小）；没有 HiDPI 档时退回同比例普通模式。
    public let resolutions: [ResolutionOption]
    /// 系统报告的全部分辨率（按桌面尺寸分组，每组含各刷新率）。
    public let allResolutions: [ResolutionOption]
    public let currentResolution: ResolutionOption?
    public let brightness: Double
    public let brightnessBackend: BrightnessBackend
    public let supportsHDR: Bool
    public let hdrEnabled: Bool?
    /// EDR 潜在余量（1 表示没有）。HDR 模式下大于 1 时可以做亮度提升。
    public let edrHeadroom: Double
    /// 当前亮度提升倍数（1 表示关闭）。
    public let boost: Double
    public let hiDPIOverride: HiDPIOverrideState
    /// 由本进程创建的虚拟屏。
    public let isOwnVirtual: Bool

    public var name: String { info.name }
    public var isBuiltIn: Bool { info.isBuiltIn }
    public var currentMode: DisplayModeInfo? { info.currentMode }
    public var refreshRates: [Double] { currentResolution?.refreshRates ?? [] }
    /// 桌面尺寸与面板像素一致（HiDPI 或 1×）。
    public var isAtNativeSize: Bool {
        currentResolution.map { $0.width == nativeWidth && $0.height == nativeHeight } ?? false
    }
    public var canBoost: Bool { hdrEnabled == true && brightnessBackend == .hdrSDR && edrHeadroom > 1.05 }
    public var isHiDPI: Bool { currentResolution?.hiDPI ?? false }
    /// 当前尺寸的另一种模式（HiDPI ↔ 普通），HiDPI 开关切的就是它。
    public var hiDPICounterpart: ResolutionOption? {
        guard let current = currentResolution else { return nil }
        return allResolutions.first { $0.width == current.width && $0.height == current.height && $0.hiDPI != current.hiDPI }
    }
    /// 这个尺寸有没有 HiDPI 模式。
    public func hasHiDPI(_ option: ResolutionOption) -> Bool {
        option.hiDPI || allResolutions.contains { $0.width == option.width && $0.height == option.height && $0.hiDPI }
    }

    public static func == (lhs: ScreenDisplay, rhs: ScreenDisplay) -> Bool {
        lhs.id == rhs.id && lhs.brightness == rhs.brightness && lhs.currentMode == rhs.currentMode
            && lhs.hdrEnabled == rhs.hdrEnabled && lhs.brightnessBackend == rhs.brightnessBackend
            && lhs.resolutions == rhs.resolutions && lhs.allResolutions == rhs.allResolutions
            && lhs.edrHeadroom == rhs.edrHeadroom && lhs.boost == rhs.boost
            && lhs.hiDPIOverride == rhs.hiDPIOverride
    }
}

/// 一个桌面尺寸（点数）及其可用刷新率。
public struct ResolutionOption: Identifiable, Equatable {
    public let width: Int
    public let height: Int
    public let hiDPI: Bool
    /// 同一尺寸的各刷新率模式，高刷在前。
    public let modes: [DisplayModeInfo]

    public var id: String { "\(width)x\(height)\(hiDPI ? "@2x" : "")" }
    public var refreshRates: [Double] { modes.map(\.refreshRate) }
    public var isCurrent: Bool { modes.contains { $0.isCurrent } }
    public var currentRefreshRate: Double? { modes.first { $0.isCurrent }?.refreshRate }

    /// 刷新率相同的模式；没有时取最高刷新率。
    public func mode(preferring rate: Double?) -> DisplayModeInfo? {
        if let rate, let match = modes.first(where: { abs($0.refreshRate - rate) < 0.5 }) {
            return match
        }
        return modes.first
    }
}

public struct BrightnessHUDValue: Identifiable, Sendable, Equatable {
    public let id: CGDirectDisplayID
    public let name: String
    public let fraction: Double

    public init(id: CGDirectDisplayID, name: String, fraction: Double) {
        self.id = id
        self.name = name
        self.fraction = fraction
    }
}

public struct VirtualScreen: Identifiable, Equatable {
    public let id: UUID
    public let spec: VirtualDisplayController.Spec
}

public enum DisplayBridgeError: LocalizedError {
    case displayNotFound
    case nativeModeUnknown
    case noHiDPIVariant

    public var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到该显示器。"
        case .nativeModeUnknown: return "无法确定原生分辨率。"
        case .noHiDPIVariant: return "这个分辨率没有对应的 HiDPI / 普通模式。"
        }
    }
}

@MainActor
public final class DisplayEngine {
    public private(set) var displays: [ScreenDisplay] = []
    /// 显示器列表、亮度或模式变化后在主线程回调。
    public var onChange: (() -> Void)?
    /// F1/F2 接管需要系统权限但事件监听创建失败时，在主线程回调。
    public var onBrightnessKeysPermissionMissing: (() -> Void)?
    public var onBrightnessKeysAdjusted: (([BrightnessHUDValue]) -> Void)?

    private let manager = DisplayManager()
    private let virtualController = VirtualDisplayController()
    private let overrideService = OverrideService()
    private let keyController = BrightnessKeyController()
    private var started = false
    private var screenObserver: NSObjectProtocol?
    private var overrideStates: [String: ScreenDisplay.HiDPIOverrideState] = [:]
    /// 进入 HDR 时由本进程关掉的夜览/原彩，离开 HDR 时恢复。
    private var suppressedNightShift = false
    private var suppressedTrueTone = false
    private var anyExternalHDR = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        manager.onDisplaysChanged = { [weak self] in
            DispatchQueue.main.async { self?.rebuild(readBrightness: true) }
        }
        manager.startMonitoringDisplayChanges()
        // HDR 开关、EDR 余量变化不一定触发 CG 重配置回调，屏幕参数通知可以补上。
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.manager.refresh() }
        }
        manager.refresh()
        keyController.displayManager = manager
        keyController.onAdjusted = { [weak self] in
            guard let self else { return }
            self.rebuild(readBrightness: false)
            let values = self.manager.displays.compactMap { info -> BrightnessHUDValue? in
                guard let controller = self.manager.brightnessController(for: info.identifier),
                      controller.backendKind == .ddc || controller.backendKind == .apple else { return nil }
                return BrightnessHUDValue(
                    id: info.identifier,
                    name: info.name,
                    fraction: self.manager.cachedBrightness(for: info.identifier)
                )
            }
            self.onBrightnessKeysAdjusted?(values)
        }
        keyController.onPermissionMissing = { [weak self] in
            DispatchQueue.main.async { self?.onBrightnessKeysPermissionMissing?() }
        }
        keyController.start()
        rebuild(readBrightness: true)
    }

    /// 退出时调用：断开虚拟屏、同步恢复 gamma 与亮度提升、还原被关掉的夜览。
    public func stop() {
        guard started else { return }
        started = false
        keyController.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        virtualController.disconnectAll()
        SoftwareDimming.shared.restoreAllSynchronously()
        EDRKeeper.shared.deactivateAll()
        restoreNightShiftIfSuppressed()
        manager.stopMonitoringDisplayChanges()
        manager.onDisplaysChanged = nil
    }

    public func refresh() {
        manager.refresh()
    }

    // MARK: 亮度

    /// 拖动滑块时调用；内部按“最新值合并”节流，不会排队重放历史值。
    public func setBrightness(_ fraction: Double, for id: CGDirectDisplayID, smooth: Bool = false) {
        guard let controller = manager.brightnessController(for: id) else { return }
        let value = min(1, max(0, fraction))
        manager.updateCachedBrightness(value, for: id)
        controller.setTarget(value, smooth: smooth)
        rebuild(readBrightness: false)
    }

    /// HDR 模式下把亮度提升到 100% 以上（利用 EDR 余量）。factor 1 表示关闭。
    public func setBoost(_ factor: Double, for id: CGDirectDisplayID) {
        guard let controller = manager.brightnessController(for: id),
              let display = displays.first(where: { $0.id == id }), display.canBoost else { return }
        controller.setBoost(min(display.edrHeadroom, max(1, factor)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.rebuild(readBrightness: false)
        }
    }

    /// 重新读取硬件亮度（DDC 读较慢，后台执行）。
    public func reloadBrightness() {
        let controllers = manager.displays.compactMap { display in
            manager.brightnessController(for: display.identifier).map { (display.identifier, $0) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let readings = controllers.compactMap { id, controller in
                controller.readCurrentFraction().map { (id, $0) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (id, value) in readings { self.manager.updateCachedBrightness(value, for: id) }
                self.rebuild(readBrightness: false)
            }
        }
    }

    // MARK: 分辨率与刷新率

    /// 切到某个桌面尺寸，尽量保持当前刷新率（例如 144Hz）。
    public func applyResolution(_ option: ResolutionOption, to id: CGDirectDisplayID,
                                completion: @escaping (Error?) -> Void) {
        let rate = displays.first { $0.id == id }?.currentMode?.refreshRate
        guard let mode = option.mode(preferring: rate) else {
            completion(DisplayBridgeError.nativeModeUnknown)
            return
        }
        applyMode(mode, to: id, completion: completion)
    }

    /// 保持当前桌面尺寸，只换刷新率。
    public func applyRefreshRate(_ rate: Double, to id: CGDirectDisplayID,
                                 completion: @escaping (Error?) -> Void) {
        guard let option = displays.first(where: { $0.id == id })?.currentResolution,
              let mode = option.modes.first(where: { abs($0.refreshRate - rate) < 0.5 }) else {
            completion(DisplayBridgeError.displayNotFound)
            return
        }
        applyMode(mode, to: id, completion: completion)
    }

    /// 切换模式。外接屏换刷新率/分辨率时可能掉出 HDR（BetterDisplay 也专门处理这种情况），
    /// 切换前处于 HDR 的，切完确认一次，掉了就重新打开。
    public func applyMode(_ mode: DisplayModeInfo, to id: CGDirectDisplayID,
                          completion: @escaping (Error?) -> Void) {
        let wasHDR = HDRService.isEnabled(id) == true
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Error?
            do { try ModeService.apply(mode: mode, to: id); result = nil } catch { result = error }
            if result == nil && wasHDR {
                Self.restoreHDRIfDropped(id)
            }
            DispatchQueue.main.async { [weak self] in
                self?.manager.refresh()
                completion(result)
            }
        }
    }

    nonisolated private static func restoreHDRIfDropped(_ id: CGDirectDisplayID) {
        // 模式切换期间 HDR 状态会短暂读成关闭；稳定后仍是关闭才算真的掉了。
        usleep(1_500_000)
        for _ in 0..<6 {
            if HDRService.isEnabled(id) == true { return }
            usleep(250_000)
        }
        NSLog("Meridian display: HDR dropped after mode change on %u, re-enabling", id)
        HDRService.setEnabled(true, for: id)
    }

    /// HiDPI 开关：当前尺寸在 HiDPI 与普通模式之间切换，保持刷新率。
    public func setHiDPI(_ enabled: Bool, for id: CGDirectDisplayID, completion: @escaping (Error?) -> Void) {
        guard let display = displays.first(where: { $0.id == id }) else {
            completion(DisplayBridgeError.displayNotFound)
            return
        }
        guard display.isHiDPI != enabled else { completion(nil); return }
        guard let option = display.hiDPICounterpart else {
            completion(DisplayBridgeError.noHiDPIVariant)
            return
        }
        applyResolution(option, to: id, completion: completion)
    }

    /// 回到面板原生尺寸：有 HiDPI 档时用 HiDPI（例如 2560×1440 HiDPI），保持当前刷新率。
    public func restoreNativeMode(for id: CGDirectDisplayID, completion: @escaping (Error?) -> Void) {
        guard let display = displays.first(where: { $0.id == id }) else {
            completion(DisplayBridgeError.displayNotFound)
            return
        }
        let candidates = display.allResolutions.filter {
            $0.width == display.nativeWidth && $0.height == display.nativeHeight
        }
        guard let option = candidates.first(where: \.hiDPI) ?? candidates.first else {
            completion(DisplayBridgeError.nativeModeUnknown)
            return
        }
        applyResolution(option, to: id, completion: completion)
    }

    // MARK: HDR

    public func setHDR(_ enabled: Bool, for id: CGDirectDisplayID, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let applied = HDRService.setEnabled(enabled, for: id)
            DispatchQueue.main.async { [weak self] in
                self?.manager.refresh()
                completion(applied == enabled)
            }
        }
    }

    // MARK: 虚拟屏

    public static var virtualPresets: [VirtualDisplayController.Spec] { VirtualDisplayController.Spec.presets }

    public var virtualScreens: [VirtualScreen] {
        virtualController.activeSpecs.map { VirtualScreen(id: $0.id, spec: $0.spec) }
    }

    public func createVirtualScreen(_ spec: VirtualDisplayController.Spec) throws {
        defer { manager.refresh() }
        _ = try virtualController.create(spec: spec)
    }

    public func disconnectVirtualScreen(_ id: UUID) {
        virtualController.disconnect(id: id)
        manager.refresh()
    }

    // MARK: HiDPI 档位（root 助手写系统覆盖文件）

    public var overrideHelperInstalled: Bool { overrideService.isInstalled }

    public func installHiDPIOverride(for id: CGDirectDisplayID) async throws -> String {
        guard let display = manager.display(with: id) else { throw DisplayBridgeError.displayNotFound }
        if !overrideService.isInstalled { try overrideService.install() }
        defer { overrideStates.removeAll(); rebuild(readBrightness: false) }
        return try await overrideService.installOverride(for: display)
    }

    public func removeHiDPIOverride(for id: CGDirectDisplayID) async throws -> String {
        guard let display = manager.display(with: id) else { throw DisplayBridgeError.displayNotFound }
        if !overrideService.isInstalled { try overrideService.install() }
        defer { overrideStates.removeAll(); rebuild(readBrightness: false) }
        return try await overrideService.removeOverride(for: display)
    }

    // MARK: 设置

    public var smoothingEnabled: Bool {
        get { AppSettings.shared.smoothingEnabled }
        set { AppSettings.shared.smoothingEnabled = newValue }
    }

    public var smoothingDurationMilliseconds: Double {
        get { AppSettings.shared.smoothingDurationMilliseconds }
        set { AppSettings.shared.smoothingDurationMilliseconds = newValue }
    }

    public var combinedDimmingPoint: Double {
        get { AppSettings.shared.combinedDimmingPoint }
        set { AppSettings.shared.combinedDimmingPoint = newValue }
    }

    public var showVirtualScreens: Bool {
        get { AppSettings.shared.showVirtualScreens }
        set { AppSettings.shared.showVirtualScreens = newValue; rebuild(readBrightness: false) }
    }

    /// 外接屏进入 HDR 时关闭夜览和原彩显示，回到 SDR 时恢复。
    public var hdrDisablesNightShift: Bool {
        get { AppSettings.shared.hdrDisablesNightShift }
        set {
            AppSettings.shared.hdrDisablesNightShift = newValue
            if newValue {
                anyExternalHDR = false
                rebuild(readBrightness: false)
            } else {
                restoreNightShiftIfSuppressed()
            }
        }
    }

    /// F1/F2 亮度键接管外接屏（需要输入监控权限）。
    public var takeOverBrightnessKeys: Bool {
        get { AppSettings.shared.takeOverBrightnessKeys }
        set {
            AppSettings.shared.takeOverBrightnessKeys = newValue
            if started { keyController.start() }
        }
    }

    public var brightnessKeysActive: Bool { keyController.permissionAvailable }

    // MARK: 内部

    private func nativeSize(of display: DisplayInfo) -> (Int, Int) {
        let info = CoreDisplayBridge.createInfoDictionary(for: display.identifier)
        let width = info?["kCGDisplayPixelWidth"] as? Int ?? display.pixelWidth
        let height = info?["kCGDisplayPixelHeight"] as? Int ?? display.pixelHeight
        return (width, height)
    }

    /// 按桌面尺寸分组：同一尺寸每个刷新率只留一个模式（优先当前模式和公开模式）。
    private func resolutionOptions(for display: DisplayInfo) -> [ResolutionOption] {
        var groups: [String: [DisplayModeInfo]] = [:]
        var order: [String] = []
        for mode in display.modes where mode.pointWidth > 0 && mode.pointHeight > 0 {
            let key = "\(mode.pointWidth)x\(mode.pointHeight)x\(mode.isHiDPI)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(mode)
        }
        let options = order.compactMap { key -> ResolutionOption? in
            guard let modes = groups[key], let first = modes.first else { return nil }
            var byRate: [Int: DisplayModeInfo] = [:]
            for mode in modes {
                let rate = Int(mode.refreshRate.rounded())
                if let existing = byRate[rate] {
                    let better = (mode.isCurrent && !existing.isCurrent)
                        || (mode.isCurrent == existing.isCurrent && mode.cgsIndex == nil && existing.cgsIndex != nil)
                    if better { byRate[rate] = mode }
                } else {
                    byRate[rate] = mode
                }
            }
            return ResolutionOption(
                width: first.pointWidth,
                height: first.pointHeight,
                hiDPI: first.isHiDPI,
                modes: byRate.values.sorted { $0.refreshRate > $1.refreshRate }
            )
        }
        return options.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.hiDPI && !$1.hiDPI
        }
    }

    /// 精选：与面板同宽高比、桌面不小于面板一半的尺寸，每个尺寸一行（同 BetterDisplay）。
    /// 同一尺寸既有 HiDPI 又有普通模式时，取与当前 HiDPI 开关一致的那个；
    /// 比面板还大的尺寸只能是 HiDPI。
    private func curatedResolutions(_ all: [ResolutionOption], native: (Int, Int)) -> [ResolutionOption] {
        let (nativeWidth, nativeHeight) = native
        guard nativeWidth > 0, nativeHeight > 0 else { return all }
        let aspect = Double(nativeWidth) / Double(nativeHeight)
        let wantHiDPI = all.first(where: \.isCurrent)?.hiDPI ?? true
        func matches(_ option: ResolutionOption) -> Bool {
            let optionAspect = Double(option.width) / Double(option.height)
            return abs(optionAspect - aspect) / aspect < 0.02 && option.width * 2 >= nativeWidth
                && (option.hiDPI || option.width <= nativeWidth)
        }
        var curated: [ResolutionOption] = []
        for option in all where matches(option) || option.isCurrent {
            if let index = curated.firstIndex(where: { $0.width == option.width && $0.height == option.height }) {
                let existing = curated[index]
                if !existing.isCurrent && (option.isCurrent || option.hiDPI == wantHiDPI) { curated[index] = option }
            } else {
                curated.append(option)
            }
        }
        return curated.sorted { $0.width > $1.width }
    }

    private func overrideState(for display: DisplayInfo, native: (Int, Int)) -> ScreenDisplay.HiDPIOverrideState {
        let key = "\(display.vendorID):\(display.productID)"
        if let cached = overrideStates[key] { return cached }
        let state: ScreenDisplay.HiDPIOverrideState
        if let installed = OverrideSupport.installedScaleResolutions(vendorID: display.vendorID, productID: display.productID) {
            let wanted = Set(OverrideSupport.defaultScaleResolutions(nativeWidth: native.0, nativeHeight: native.1))
            state = wanted.isSubset(of: Set(installed)) ? .upToDate : .outdated
        } else {
            state = .none
        }
        overrideStates[key] = state
        return state
    }

    private func edrHeadroom(for id: CGDirectDisplayID) -> Double {
        let screen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == id
        }
        return Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
    }

    /// 外接屏进入/离开 HDR 时开关夜览与原彩（仅在用户打开该选项时）。
    private func updateNightShift(for displays: [ScreenDisplay]) {
        let hdrNow = displays.contains { !$0.isBuiltIn && !$0.isOwnVirtual && $0.hdrEnabled == true }
        defer { anyExternalHDR = hdrNow }
        guard AppSettings.shared.hdrDisablesNightShift, hdrNow != anyExternalHDR else { return }
        let control = BlueLightControl.shared
        if hdrNow {
            if control.nightShiftActive {
                control.setNightShift(false)
                suppressedNightShift = true
            }
            if control.trueToneActive {
                control.setTrueTone(false)
                suppressedTrueTone = true
            }
        } else {
            restoreNightShiftIfSuppressed()
        }
    }

    private func restoreNightShiftIfSuppressed() {
        if suppressedNightShift { BlueLightControl.shared.setNightShift(true) }
        if suppressedTrueTone { BlueLightControl.shared.setTrueTone(true) }
        suppressedNightShift = false
        suppressedTrueTone = false
    }

    private func rebuild(readBrightness: Bool) {
        let showVirtual = AppSettings.shared.showVirtualScreens
        displays = manager.displays.compactMap { info in
            let own = virtualController.manages(displayID: info.identifier)
            if info.isVirtual && !own && !showVirtual { return nil }
            let native = nativeSize(of: info)
            let controller = manager.brightnessController(for: info.identifier)
            var backend = ScreenDisplay.BrightnessBackend(rawValue: controller?.backendKind.rawValue ?? "unavailable")
                ?? .unavailable
            if controller?.controlsHDRSDRBrightness == true { backend = .hdrSDR }
            let supportsHDR = HDRService.isAvailable && HDRService.supportsHDR(info.identifier)
            let all = resolutionOptions(for: info)
            return ScreenDisplay(
                info: info,
                nativeWidth: native.0,
                nativeHeight: native.1,
                resolutions: curatedResolutions(all, native: native),
                allResolutions: all,
                currentResolution: all.first(where: \.isCurrent),
                brightness: manager.cachedBrightness(for: info.identifier),
                brightnessBackend: backend,
                supportsHDR: supportsHDR,
                hdrEnabled: supportsHDR ? HDRService.isEnabled(info.identifier) : nil,
                edrHeadroom: edrHeadroom(for: info.identifier),
                boost: controller?.boostFactor ?? 1,
                hiDPIOverride: info.isBuiltIn || own ? .none : overrideState(for: info, native: native),
                isOwnVirtual: own
            )
        }
        updateNightShift(for: displays)
        onChange?()
        if readBrightness { reloadBrightness() }
    }
}
