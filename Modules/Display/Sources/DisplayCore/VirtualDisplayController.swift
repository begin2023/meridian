import CoreGraphics
import DisplayPrivate
import Foundation

/// Creates and tears down virtual screens through the private CGVirtualDisplay
/// ObjC classes exported by CoreGraphics. Construction recipe requirements on
/// macOS 14+: a non-zero vendor id and a serial number unique per virtual
/// display; keep a strong reference for the display's lifetime (releasing it
/// destroys the screen).
public final class VirtualDisplayController {
    public struct Spec: Equatable {
        public let name: String
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let refreshRate: Double
        public let hiDPI: Bool

        public init(name: String, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, hiDPI: Bool = true) {
            self.name = name
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.refreshRate = refreshRate
            self.hiDPI = hiDPI
        }

        public static let presets: [Spec] = [
            Spec(name: "1080p 16:9", pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60),
            Spec(name: "1440p 16:9", pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60),
            Spec(name: "4K 16:9", pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
            Spec(name: "5K 16:9", pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60),
            Spec(name: "UW 21:9", pixelWidth: 3440, pixelHeight: 1440, refreshRate: 60),
            Spec(name: "Super UW 32:9", pixelWidth: 5120, pixelHeight: 1440, refreshRate: 60),
        ]
    }

    public enum VirtualDisplayError: LocalizedError {
        case creationFailed(String)
        case unknownSpec

        public var errorDescription: String? {
            switch self {
            case .creationFailed(let detail):
                return "虚拟屏幕创建失败：\(detail)"
            case .unknownSpec:
                return "虚拟屏幕配置不存在。"
            }
        }
    }

    private struct Instance {
        let display: CGVirtualDisplay
        let spec: Spec
    }

    /// One active upsample session: a virtual display whose framebuffer the
    /// physical panel mirrors. The desktop renders at the virtual resolution
    /// and WindowServer downsamples to the panel. This software scaling
    /// applies immediately without reconnecting the display.
    public struct MirrorSession: Equatable {
        public let instanceID: UUID
        public let virtualDisplayID: CGDirectDisplayID
        public let physicalDisplayID: CGDirectDisplayID
        public let spec: Spec
    }

    private var instances: [UUID: Instance] = [:]
    private var mirrorSession: MirrorSession?
    private var serialState: UInt32 = 1
    private let serialLock = NSLock()

    public init() {}

    public var activeSpecs: [(id: UUID, spec: Spec)] {
        instances.map { ($0.key, $0.value.spec) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public var activeMirrorSession: MirrorSession? {
        mirrorSession
    }

    /// True when the display id belongs to a screen this controller created.
    public func manages(displayID: CGDirectDisplayID) -> Bool {
        instances.values.contains { $0.display.displayID == displayID }
    }

    /// 系统可能在睡眠/唤醒或高负载后自行拆掉镜像，但虚拟屏对象还留在本进程里。
    /// 此时清掉会话，避免界面一直显示“5K 渲染已开启”而实际已经回到原生模式。
    @discardableResult
    public func discardDetachedSession() -> Bool {
        guard let session = mirrorSession else { return false }
        guard CGDisplayMirrorsDisplay(session.physicalDisplayID) != session.virtualDisplayID else { return false }
        instances.removeValue(forKey: session.instanceID)
        mirrorSession = nil
        return true
    }

    /// Creates a virtual screen and returns once it appears in the CG display
    /// list (or throws after a timeout). Must run with a usable main run loop;
    /// call from the main queue.
    public func create(spec: Spec, timeout: TimeInterval = 5) throws -> CGDirectDisplayID {
        try createInstance(spec: spec, instanceID: UUID())
    }

    private func createInstance(spec: Spec, instanceID: UUID) throws -> CGDirectDisplayID {
        let serial = nextSerialNumber()
        let descriptor = CGVirtualDisplayDescriptor()
        let eventQueue = DispatchQueue(label: "app.meridian.display.virtualdisplay.\(serial)")
        descriptor.setDispatchQueue(eventQueue)
        descriptor.name = spec.name
        descriptor.maxPixelsWide = UInt(spec.pixelWidth)
        descriptor.maxPixelsHigh = UInt(spec.pixelHeight)
        // Physical size affects default HiDPI scaling assumptions; 16:9
        // panels around 27" are a sane neutral choice.
        let diagonal = sqrt(Double(spec.pixelWidth * spec.pixelWidth + spec.pixelHeight * spec.pixelHeight))
        let diagonalInches = diagonal / 96 * 2.2
        descriptor.sizeInMillimeters = CGSize(width: Double(spec.pixelWidth) / diagonal * diagonalInches * 25.4, height: Double(spec.pixelHeight) / diagonal * diagonalInches * 25.4)
        // macOS 14+ requires a non-zero vendor id and per-display unique
        // serial; product id stays zero (matches the Chromium recipe).
        descriptor.vendorID = 505
        descriptor.productID = 0
        descriptor.serialNum = serial
        descriptor.serialNumber = serial

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.creationFailed("CGVirtualDisplay 返回空。")
        }

        let settings = CGVirtualDisplaySettings()
        // Mode carries the full pixel size; with hiDPI enabled macOS
        // additionally advertises Retina modes at half the pixel size in
        // points (measured recipe, macOS 26).
        var modes = [
            CGVirtualDisplayMode(
                width: UInt(spec.pixelWidth),
                height: UInt(spec.pixelHeight),
                refreshRate: spec.refreshRate
            ),
        ]
        // 实测（macOS 27.2）：系统只为声明过的模式生成 2× Retina 版本，不会从全像素模式
        // 自动推出“点数 = 像素/2”的那一档；HiDPI 规格必须显式声明半尺寸模式。
        if spec.hiDPI {
            modes.append(CGVirtualDisplayMode(
                width: UInt(spec.pixelWidth / 2),
                height: UInt(spec.pixelHeight / 2),
                refreshRate: spec.refreshRate
            ))
        }
        settings.modes = modes.compactMap { $0 }
        settings.hiDPI = spec.hiDPI ? 1 : 0

        guard display.apply(settings) else {
            throw VirtualDisplayError.creationFailed("应用显示模式失败。")
        }

        let displayID = display.displayID
        if getenv("DISPLAYLAB_DEBUG_VIRTUAL") != nil {
            let modeCount = display.modes?.count ?? -1
            NSLog("DisplayLab virtual: displayID=%u modes=%ld hiDPI=%lu",
                  displayID, modeCount, display.hiDPI)
        }

        // Newer macOS builds create the display in a disabled state; enable
        // it explicitly through the CGS configuration transaction.
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            CGSConfigureDisplayEnabled(config, displayID, 1)
            // 会话级配置：退出登录即恢复，不把临时虚拟屏写进用户的显示器偏好。
            CGCompleteDisplayConfiguration(config, .forSession)
        }

        instances[instanceID] = Instance(display: display, spec: spec)
        return displayID
    }

    /// Creates a virtual screen at the spec's pixel size and makes the
    /// physical display mirror it, so the desktop runs at the (typically 2×)
    /// virtual resolution. All display changes happen from this single
    /// user-initiated call — no retries, no background experiments; failures
    /// leave the physical display untouched or immediately restored.
    public func createMirroredUpsample(
        for physical: CGDirectDisplayID,
        spec: Spec,
        timeout: TimeInterval = 5
    ) throws -> MirrorSession {
        guard mirrorSession == nil else {
            throw VirtualDisplayError.creationFailed("已有一个上采样会话，请先关闭它。")
        }

        let instanceID = UUID()
        let virtualID = try createInstance(spec: spec, instanceID: instanceID)

        // Wait until WindowServer actually scans out the virtual display
        // (CGDisplayIsOnline stays false for virtual screens; pixel width is
        // the reliable readiness signal) before attaching the mirror.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, CGDisplayPixelsWide(virtualID) <= 0 {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard CGDisplayPixelsWide(virtualID) > 0 else {
            instances.removeValue(forKey: instanceID)
            throw VirtualDisplayError.creationFailed("虚拟屏幕未能在限时内上线，已自动丢弃。")
        }

        // 系统会按物理尺寸给新虚拟屏挑一个“默认缩放”（实测为 1920×1080 或半尺寸 Retina），
        // 必须显式选中目标模式：HiDPI 取 点数 = 像素/2 的 Retina 模式，否则取 1× 全像素模式。
        // 公开模式表在部分进程（无 WindowServer 连接的 CLI）里对虚拟屏返回空，
        // 此时回退到 CGS 私有模式表——两者都用 CGDisplayBounds 点数核验。
        guard Self.selectTargetMode(on: virtualID, spec: spec) else {
            instances.removeValue(forKey: instanceID)
            throw VirtualDisplayError.creationFailed("虚拟屏没有提供 \(Self.describe(spec)) 模式，已自动丢弃。")
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            instances.removeValue(forKey: instanceID)
            throw VirtualDisplayError.creationFailed("无法开始显示器配置事务。")
        }
        let mirrorError = CGConfigureDisplayMirrorOfDisplay(config, physical, virtualID)
        guard mirrorError == .success else {
            CGCancelDisplayConfiguration(config)
            instances.removeValue(forKey: instanceID)
            throw VirtualDisplayError.creationFailed("镜像配置失败（CGError \(mirrorError.rawValue)）。物理显示器未改动。")
        }
        let completeError = CGCompleteDisplayConfiguration(config, .forSession)
        guard completeError == .success else {
            // Best-effort restore: drop the mirror and the virtual screen.
            try? teardownMirroredUpsample()
            throw VirtualDisplayError.creationFailed("提交镜像配置失败（CGError \(completeError.rawValue)）。已自动还原。")
        }

        // WindowServer can accept the transaction and still not apply the
        // mirror (observed between two virtual screens, which carry no
        // hardware scanout). Verify the relationship actually exists and roll
        // everything back when it does not, so the panel is never left in a
        // half-applied state.
        var attached = false
        let verifyDeadline = Date().addingTimeInterval(3)
        while Date() < verifyDeadline {
            if CGDisplayMirrorsDisplay(physical) == virtualID {
                attached = true
                break
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        guard attached else {
            try? teardownMirroredUpsample()
            throw VirtualDisplayError.creationFailed("系统接受了镜像配置但未应用（未生效），已自动还原，显示器未改动。")
        }

        // 建立镜像后再确认一次模式（镜像组可能回落到双方都支持的模式）。
        if !Self.waitForMatch(virtualID, spec, timeout: 0.5) {
            _ = Self.selectTargetMode(on: virtualID, spec: spec)
        }
        guard Self.waitForMatch(virtualID, spec, timeout: 3) else {
            let bounds = CGDisplayBounds(virtualID).size
            mirrorSession = MirrorSession(instanceID: instanceID, virtualDisplayID: virtualID,
                                          physicalDisplayID: physical, spec: spec)
            try? teardownMirroredUpsample()
            throw VirtualDisplayError.creationFailed(
                "系统没有采用 \(Self.describe(spec))（实际 \(Int(bounds.width))×\(Int(bounds.height))），已自动还原。")
        }

        let session = MirrorSession(
            instanceID: instanceID,
            virtualDisplayID: virtualID,
            physicalDisplayID: physical,
            spec: spec
        )
        mirrorSession = session
        return session
    }

    private static func describe(_ spec: Spec) -> String {
        spec.hiDPI ? "\(spec.pixelWidth / 2)×\(spec.pixelHeight / 2) HiDPI" : "\(spec.pixelWidth)×\(spec.pixelHeight)"
    }

    /// 目标模式在桌面上的点数尺寸。HiDPI 是像素的一半，LoDPI 与像素一致。
    private static func points(for spec: Spec) -> CGSize {
        CGSize(width: spec.hiDPI ? spec.pixelWidth / 2 : spec.pixelWidth,
               height: spec.hiDPI ? spec.pixelHeight / 2 : spec.pixelHeight)
    }

    /// 当前模式是否就是目标：GUI 进程用 CGDisplayCopyDisplayMode 核验真实像素，
    /// 无 WindowServer 连接的进程回退到 CGS 模式表（含 HiDPI/density 标记）。
    private static func currentMatches(_ display: CGDirectDisplayID, _ spec: Spec) -> Bool {
        let size = points(for: spec)
        if let current = CGDisplayCopyDisplayMode(display) {
            return current.width == Int(size.width) && current.height == Int(size.height)
                && current.pixelWidth == spec.pixelWidth && current.pixelHeight == spec.pixelHeight
        }
        let cgs = ModeService.cgsModes(for: display)
        if let current = cgs.first(where: { $0.isCurrent }) {
            return current.pixelWidth == Int(size.width) && current.pixelHeight == Int(size.height)
                && current.isHiDPI == spec.hiDPI
        }
        // 最后只剩点数可用于判断（至少保证桌面尺寸正确）。
        let bounds = CGDisplayBounds(display).size
        return abs(bounds.width - size.width) < 1 && abs(bounds.height - size.height) < 1
    }

    private static func waitForMatch(_ display: CGDirectDisplayID, _ spec: Spec, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentMatches(display, spec) { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return currentMatches(display, spec)
    }

    /// 选择目标模式。优先公开模式表（GUI 进程），不可用时回退到 CGS 私有表。
    @discardableResult
    private static func selectTargetMode(on display: CGDirectDisplayID, spec: Spec) -> Bool {
        let size = points(for: spec)
        if currentMatches(display, spec) { return true }

        // 1) 公开模式表：width/height 是点数，pixelWidth 是帧缓冲像素。
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        if let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
           let wanted = modes.filter({
               $0.width == Int(size.width) && $0.height == Int(size.height)
                   && $0.pixelWidth == spec.pixelWidth
           }).max(by: { $0.refreshRate < $1.refreshRate }) {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                CGConfigureDisplayWithDisplayMode(config, display, wanted, nil)
                CGCompleteDisplayConfiguration(config, .forSession)
            }
            if waitForMatch(display, spec, timeout: 2) { return true }
        }

        // 2) CGS 私有模式表：对虚拟屏，description.width 记录的正是点数，
        //    density ≥ 1.5 表示 HiDPI。CLI 进程的公开表为空，只能走这里。
        let cgs = ModeService.cgsModes(for: display)
        let exact = cgs.filter {
            $0.pixelWidth == Int(size.width) && $0.pixelHeight == Int(size.height)
                && $0.isHiDPI == spec.hiDPI
        }
        let fallback = cgs.filter { $0.pixelWidth == Int(size.width) && $0.pixelHeight == Int(size.height) }
        if let wanted = (exact.isEmpty ? fallback : exact).max(by: { $0.refreshRate < $1.refreshRate }) {
            try? ModeService.apply(mode: wanted, to: display)
            if waitForMatch(display, spec, timeout: 2) { return true }
        }
        return false
    }

    /// Removes the mirror (panel returns to its own mode) and destroys the
    /// virtual screen. If the app dies without this running, releasing the
    /// virtual display still collapses the mirror set automatically.
    public func teardownMirroredUpsample() throws {
        guard let session = mirrorSession else { return }
        mirrorSession = nil
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            // kCGNullDisplayMirror is 0: detaches the physical display from
            // any mirror set.
            CGConfigureDisplayMirrorOfDisplay(config, session.physicalDisplayID, 0)
            CGCompleteDisplayConfiguration(config, .forSession)
        }
        instances.removeValue(forKey: session.instanceID)
    }

    public func disconnect(id: UUID) {
        instances.removeValue(forKey: id)
    }

    public func disconnectAll() {
        instances.removeAll()
    }

    /// Persistent "stored virtual screens" would reconnect across launches;
    /// v1 keeps everything in-session, so this is a no-op hook.
    public func restoreIfNeeded() {}

    private func nextSerialNumber() -> UInt32 {
        serialLock.lock()
        defer { serialLock.unlock() }
        serialState += 1
        return UInt32(truncatingIfNeeded: serialState) ^ UInt32(truncatingIfNeeded: getpid())
    }
}
