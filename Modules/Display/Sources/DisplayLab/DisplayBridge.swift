import AppKit
import CoreGraphics
@_exported import DisplayCore

/// 供宿主进程内直接使用的类型化接口：亮度、分辨率、HDR、上采样、虚拟屏与 HiDPI 覆盖。
///
/// 所有方法在主线程调用；耗时的硬件操作内部转到后台队列，结果在主线程回调。
public struct ScreenDisplay: Identifiable, Equatable {
    public enum BrightnessBackend: String, Sendable {
        case ddc, apple, gammaOnly, unavailable
    }

    public enum Upsample: Equatable, Sendable {
        case off
        case moreSpace
        case hiDPI
    }

    public var id: CGDirectDisplayID { info.identifier }
    public let info: DisplayInfo
    public let nativeWidth: Int
    public let nativeHeight: Int
    /// 菜单级精选模式：当前模式、原生分辨率各刷新率、标准 HiDPI 缩放档。
    public let quickModes: [DisplayModeInfo]
    public let brightness: Double
    public let brightnessBackend: BrightnessBackend
    public let supportsHDR: Bool
    public let hdrEnabled: Bool?
    public let upsample: Upsample
    /// 由本进程创建的虚拟屏（包括上采样使用的虚拟屏）。
    public let isOwnVirtual: Bool

    public var name: String { info.name }
    public var isBuiltIn: Bool { info.isBuiltIn }
    public var currentMode: DisplayModeInfo? { info.currentMode }
    public var isAtNativeMode: Bool {
        guard let mode = info.currentMode else { return false }
        return mode.pixelWidth == nativeWidth && mode.pixelHeight == nativeHeight && !mode.isHiDPI
    }

    public static func == (lhs: ScreenDisplay, rhs: ScreenDisplay) -> Bool {
        lhs.id == rhs.id && lhs.brightness == rhs.brightness && lhs.currentMode == rhs.currentMode
            && lhs.hdrEnabled == rhs.hdrEnabled && lhs.upsample == rhs.upsample
            && lhs.brightnessBackend == rhs.brightnessBackend && lhs.quickModes == rhs.quickModes
    }
}

public struct BrightnessHUDValue: Sendable, Equatable {
    public let name: String
    public let fraction: Double

    public init(name: String, fraction: Double) {
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

    public var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到该显示器。"
        case .nativeModeUnknown: return "无法确定原生分辨率。"
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
    private var hdrCache: [CGDirectDisplayID: Bool?] = [:]

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        manager.onDisplaysChanged = { [weak self] in
            DispatchQueue.main.async { self?.rebuild(readBrightness: true) }
        }
        manager.startMonitoringDisplayChanges()
        manager.refresh()
        keyController.displayManager = manager
        keyController.onAdjusted = { [weak self] in
            guard let self else { return }
            self.rebuild(readBrightness: false)
            let values = self.manager.displays.compactMap { info -> BrightnessHUDValue? in
                guard let controller = self.manager.brightnessController(for: info.identifier),
                      controller.backendKind == .ddc || controller.backendKind == .apple else { return nil }
                return BrightnessHUDValue(name: info.name, fraction: self.manager.cachedBrightness(for: info.identifier))
            }
            self.onBrightnessKeysAdjusted?(values)
        }
        keyController.onPermissionMissing = { [weak self] in
            DispatchQueue.main.async { self?.onBrightnessKeysPermissionMissing?() }
        }
        keyController.start()
        rebuild(readBrightness: true)
    }

    /// 退出时调用：撤销上采样镜像、断开虚拟屏、同步恢复软件调光的 gamma。
    public func stop() {
        guard started else { return }
        started = false
        keyController.stop()
        if virtualController.activeMirrorSession != nil {
            try? virtualController.teardownMirroredUpsample()
        }
        virtualController.disconnectAll()
        SoftwareDimming.shared.restoreAllSynchronously()
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

    // MARK: 分辨率

    public func allModes(for id: CGDirectDisplayID) -> [DisplayModeInfo] {
        manager.display(with: id)?.sortedModes ?? []
    }

    public func applyMode(_ mode: DisplayModeInfo, to id: CGDirectDisplayID,
                          completion: @escaping (Error?) -> Void) {
        if let session = virtualController.activeMirrorSession, session.physicalDisplayID == id {
            try? virtualController.teardownMirroredUpsample()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Error?
            do { try ModeService.apply(mode: mode, to: id); result = nil } catch { result = error }
            DispatchQueue.main.async { [weak self] in
                self?.manager.refresh()
                completion(result)
            }
        }
    }

    public func restoreNativeMode(for id: CGDirectDisplayID, completion: @escaping (Error?) -> Void) {
        do {
            let mode = try nativeMode(for: id)
            applyMode(mode, to: id, completion: completion)
        } catch {
            completion(error)
        }
    }

    // MARK: HDR

    public func setHDR(_ enabled: Bool, for id: CGDirectDisplayID, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let applied = HDRService.setEnabled(enabled, for: id)
            DispatchQueue.main.async { [weak self] in
                self?.hdrCache[id] = nil
                self?.manager.refresh()
                completion(applied == enabled)
            }
        }
    }

    // MARK: 上采样（虚拟屏镜像到物理面板）

    /// refreshRate 传 nil 时跟随显示器当前刷新率；调用方可传 60 等固定值以避免高刷下的画面闪烁。
    public func enableUpsample(for id: CGDirectDisplayID, hiDPI: Bool, refreshRate: Double? = nil) throws {
        guard let display = manager.display(with: id) else { throw DisplayBridgeError.displayNotFound }
        if virtualController.activeMirrorSession != nil {
            try virtualController.teardownMirroredUpsample()
        }
        let (width, height) = nativeSize(of: display)
        let spec = VirtualDisplayController.Spec(
            name: hiDPI ? "Meridian 上采样 HiDPI" : "Meridian 上采样",
            pixelWidth: width * 2,
            pixelHeight: height * 2,
            refreshRate: refreshRate ?? display.currentMode?.refreshRate ?? 60,
            hiDPI: hiDPI
        )
        defer { manager.refresh() }
        _ = try virtualController.createMirroredUpsample(for: id, spec: spec)
    }

    public func disableUpsample() throws {
        defer { manager.refresh() }
        try virtualController.teardownMirroredUpsample()
    }

    // MARK: 虚拟屏

    public static var virtualPresets: [VirtualDisplayController.Spec] { VirtualDisplayController.Spec.presets }

    public var virtualScreens: [VirtualScreen] {
        let mirrorID = virtualController.activeMirrorSession?.instanceID
        return virtualController.activeSpecs
            .filter { $0.id != mirrorID }
            .map { VirtualScreen(id: $0.id, spec: $0.spec) }
    }

    public func createVirtualScreen(_ spec: VirtualDisplayController.Spec) throws {
        defer { manager.refresh() }
        _ = try virtualController.create(spec: spec)
    }

    public func disconnectVirtualScreen(_ id: UUID) {
        virtualController.disconnect(id: id)
        manager.refresh()
    }

    // MARK: HiDPI 覆盖（root 助手）

    public var overrideHelperInstalled: Bool { overrideService.isInstalled }

    public func installOverrideHelper() throws { try overrideService.install() }

    public func installHiDPIOverride(for id: CGDirectDisplayID) async throws -> String {
        guard let display = manager.display(with: id) else { throw DisplayBridgeError.displayNotFound }
        if !overrideService.isInstalled { try overrideService.install() }
        return try await overrideService.installOverride(for: display)
    }

    public func removeHiDPIOverride(for id: CGDirectDisplayID) async throws -> String {
        guard let display = manager.display(with: id) else { throw DisplayBridgeError.displayNotFound }
        if !overrideService.isInstalled { try overrideService.install() }
        return try await overrideService.removeOverride(for: display)
    }

    public func installedOverrides() async -> [String] {
        await overrideService.installedOverrides()
    }

    public func hasOverride(for id: CGDirectDisplayID, in list: [String]) -> Bool {
        guard let display = manager.display(with: id) else { return false }
        let key = String(format: "%x:%x", display.vendorID, display.productID)
        return list.contains { $0.lowercased() == key }
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

    private func nativeMode(for id: CGDirectDisplayID) throws -> DisplayModeInfo {
        guard let display = manager.display(with: id) else { throw DisplayBridgeError.displayNotFound }
        let (width, height) = nativeSize(of: display)
        guard width > 0, height > 0 else { throw DisplayBridgeError.nativeModeUnknown }
        // 原生 = 1× 全像素模式；同像素的 HiDPI 模式（看起来只有一半大）不算原生
        let candidates = display.sortedModes.filter { $0.pixelWidth == width && $0.pixelHeight == height }
        let lowDPI = candidates.filter { !$0.isHiDPI }
        guard let best = (lowDPI.isEmpty ? candidates : lowDPI)
            .max(by: { $0.refreshRate < $1.refreshRate }) else {
            throw DisplayBridgeError.nativeModeUnknown
        }
        return best
    }

    private func quickModes(for display: DisplayInfo, native: (Int, Int)) -> [DisplayModeInfo] {
        let (nativeWidth, nativeHeight) = native
        guard nativeWidth > 0, nativeHeight > 0 else { return display.sortedModes }
        let nativeAspect = Double(nativeWidth) / Double(nativeHeight)
        let standardSteps: Set<Double> = [0.5, 0.625, 0.75]
        var seen = Set<String>()
        var result: [DisplayModeInfo] = []
        for mode in display.sortedModes {
            if !mode.isCurrent {
                let matchesNative = mode.pixelWidth == nativeWidth && mode.pixelHeight == nativeHeight
                let step = Double(mode.pixelWidth) / Double(nativeWidth)
                let aspect = Double(mode.pixelWidth) / Double(mode.pixelHeight)
                let aspectMatches = abs(aspect - nativeAspect) / nativeAspect < 0.02
                let standard = mode.isHiDPI && mode.pixelWidth < nativeWidth
                    && mode.pixelHeight < nativeHeight && standardSteps.contains(step)
                guard matchesNative || (aspectMatches && standard) else { continue }
            }
            guard seen.insert(mode.label).inserted else { continue }
            result.append(mode)
        }
        return result
    }

    private func rebuild(readBrightness: Bool) {
        // 镜像可能已被系统自行拆掉；先丢弃这种“幽灵会话”，界面才不会一直显示 5K 已开启。
        virtualController.discardDetachedSession()
        let mirror = virtualController.activeMirrorSession
        let showVirtual = AppSettings.shared.showVirtualScreens
        displays = manager.displays.compactMap { info in
            let own = virtualController.manages(displayID: info.identifier)
            if own && mirror?.virtualDisplayID == info.identifier { return nil }
            if info.isVirtual && !own && !showVirtual { return nil }
            let native = nativeSize(of: info)
            let controller = manager.brightnessController(for: info.identifier)
            let backend = ScreenDisplay.BrightnessBackend(rawValue: controller?.backendKind.rawValue ?? "unavailable")
                ?? .unavailable
            let supportsHDR = HDRService.isAvailable && HDRService.supportsHDR(info.identifier)
            let hdr: Bool?
            if let cached = hdrCache[info.identifier] {
                hdr = cached
            } else {
                hdr = supportsHDR ? HDRService.isEnabled(info.identifier) : nil
                hdrCache[info.identifier] = hdr
            }
            var upsample = ScreenDisplay.Upsample.off
            if let mirror, mirror.physicalDisplayID == info.identifier {
                upsample = mirror.spec.hiDPI ? .hiDPI : .moreSpace
            }
            return ScreenDisplay(
                info: info,
                nativeWidth: native.0,
                nativeHeight: native.1,
                quickModes: quickModes(for: info, native: native),
                brightness: manager.cachedBrightness(for: info.identifier),
                brightnessBackend: backend,
                supportsHDR: supportsHDR,
                hdrEnabled: hdr,
                upsample: upsample,
                isOwnVirtual: own
            )
        }
        onChange?()
        if readBrightness { reloadBrightness() }
    }
}
