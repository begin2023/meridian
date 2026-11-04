import CoreGraphics

/// 模式可用性校验：只有“链路扛得住”的档位才允许出现在列表里、才允许切换。
///
/// WindowServer 会把每个帧缓冲尺寸与显示器 EDID 里的全部链路 timing 做笛卡尔积。
/// 同一刷新率下若没有与帧缓冲同宽高比的真实 timing，它就挑一个尺寸对不上的 timing 硬扛，
/// 例如把 5120×2880 的帧缓冲塞进 1280×1024@75：桌面几何仍报告 2560×1440，但链路只收到
/// 1280×1024 的信息量，画面被非等比放大（横向 4.0 倍、纵向 2.8125 倍），于是又糊又变形。
/// 这类“借位”模式必须挡在选择列表之外，否则用户点一下就会掉进这个状态。
///
/// 判据：真实链路 timing = 像素等于点数、非 HiDPI 的模式（即显示器真正接收的信号尺寸）。
/// 一个模式可渲染，当且仅当存在与它**帧缓冲**同宽高比、同刷新率的真实 timing。
/// 该判据在 Q27G2G3R4B（1440p 面板 + HiDPI 覆盖档位）的 146 条 WindowServer 模式上
/// 逐条核对过：只命中 5120×2880 的 75/72/70/56Hz 四条借位模式，144/120/60/50 全部保留。
public enum ModeValidation {
    /// 真实链路 timing：按 1 倍像素直接送给显示器的模式。
    public static func carrierTimings(in modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
        modes.filter {
            !$0.isHiDPI
                && $0.pixelWidth == $0.pointWidth
                && $0.pixelHeight == $0.pointHeight
                && $0.pixelWidth > 0 && $0.pixelHeight > 0
        }
    }

    /// 过滤掉借位模式，保留原有顺序。当前模式始终保留，避免界面失去选中项。
    /// 一个真实 timing 都拿不到时（例如只暴露 HiDPI 档的虚拟屏）不做判断，原样返回。
    public static func usableModes(in modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
        let carriers = carrierTimings(in: modes)
        guard !carriers.isEmpty else { return modes }
        return modes.filter { $0.isCurrent || isRenderable($0, carriers: carriers) }
    }

    public static func isRenderable(_ mode: DisplayModeInfo, in modes: [DisplayModeInfo]) -> Bool {
        let carriers = carrierTimings(in: modes)
        guard !carriers.isEmpty else { return true }
        return isRenderable(mode, carriers: carriers)
    }

    private static func isRenderable(_ mode: DisplayModeInfo, carriers: [DisplayModeInfo]) -> Bool {
        guard mode.pixelWidth > 0, mode.pixelHeight > 0 else { return false }
        let target = Double(mode.pixelWidth) / Double(mode.pixelHeight)
        return carriers.contains { carrier in
            let aspect = Double(carrier.pixelWidth) / Double(carrier.pixelHeight)
            return abs(aspect - target) / target < 0.02
                && abs(carrier.refreshRate - mode.refreshRate) < 0.5
        }
    }
}
