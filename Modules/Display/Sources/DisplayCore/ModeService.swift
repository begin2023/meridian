import CoreGraphics
import DisplayPrivate

/// Enumerates and (from milestone 4) switches display modes. Public
/// CoreGraphics modes are preferred for switching; the CGS private table
/// supplements them with modes WindowServer does not advertise, including
/// entries whose HiDPI status is only visible through `density`.
public enum ModeService {
    /// Union of public and CGS modes, public entries first. CGS supplies the
    /// modes WindowServer hides from the public list.
    public static func modes(for display: CGDirectDisplayID) -> [DisplayModeInfo] {
        var result = publicModes(for: display)
        let known = Set(result.map { "\($0.pixelWidth)x\($0.pixelHeight)x\(Int($0.refreshRate))x\($0.isHiDPI)" })
        for mode in cgsModes(for: display) {
            let key = "\(mode.pixelWidth)x\(mode.pixelHeight)x\(Int(mode.refreshRate))x\(mode.isHiDPI)"
            if !known.contains(key) {
                result.append(mode)
            }
        }
        return result
    }

    /// Full CGS mode table. Length 0xD4 matches the reverse-engineered
    /// description layout; a bogus layout would surface as garbage
    /// dimensions, which the smoke test cross-checks against public modes.
    public static func cgsModes(for display: CGDirectDisplayID) -> [DisplayModeInfo] {
        var count: Int32 = 0
        guard CGSGetNumberOfDisplayModes(display, &count) == .success, count > 0 else {
            return []
        }

        var currentIndex: Int32 = -1
        CGSGetCurrentDisplayMode(display, &currentIndex)

        var modes: [DisplayModeInfo] = []
        modes.reserveCapacity(Int(count))
        for index in 0..<count {
            var description = CGSDisplayModeDescription()
            guard CGSGetDisplayModeDescriptionOfLength(display, index, &description, Int32(MemoryLayout<CGSDisplayModeDescription>.size)) == .success else {
                continue
            }
            let width = Int(description.width)
            let height = Int(description.height)
            guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
                continue
            }
            let refresh = Double(description.refreshRate)
            let density = CGFloat(description.density)
            // CGS 描述里的宽高是点数；乘以 density 才是帧缓冲像素，和公开模式表保持同一单位。
            let scale = density >= 1 ? density : 1
            modes.append(
                DisplayModeInfo(
                    pixelWidth: Int((CGFloat(width) * scale).rounded()),
                    pixelHeight: Int((CGFloat(height) * scale).rounded()),
                    pointWidth: width,
                    pointHeight: height,
                    refreshRate: refresh,
                    isHiDPI: density >= 1.5,
                    cgsIndex: Int(index),
                    isCurrent: Int32(index) == currentIndex
                )
            )
        }
        return modes
    }

    /// Modes exposed through the public API, including duplicate low
    /// resolution variants of HiDPI modes.
    public static func publicModes(for display: CGDirectDisplayID) -> [DisplayModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
            return []
        }

        let current = CGDisplayCopyDisplayMode(display)
        return rawModes.map { mode in
            let isCurrent = current != nil && CFEqual(current!, mode)
            return DisplayModeInfo(
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                pointWidth: mode.width,
                pointHeight: mode.height,
                refreshRate: mode.refreshRate,
                isHiDPI: DisplayModeInfo.ratio(mode.pixelWidth, mode.width) >= 1.5,
                cgsIndex: nil,
                isCurrent: isCurrent
            )
        }
    }

    /// Resolves a concrete CGDisplayMode for a public (cgsIndex == nil) mode.
    public static func publicMode(matching info: DisplayModeInfo, for display: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
            return nil
        }
        return rawModes.first { mode in
            let dimensionsMatch = mode.pixelWidth == info.pixelWidth
                && mode.pixelHeight == info.pixelHeight
            let isHiDPI = DisplayModeInfo.ratio(mode.pixelWidth, mode.width) >= 1.5
            let kindMatches = isHiDPI == info.isHiDPI
            let refreshMatches = abs(mode.refreshRate - info.refreshRate) < 0.5
            return dimensionsMatch && kindMatches && refreshMatches
        }
    }

    /// Switches the display to a previously enumerated mode. Public modes go
    /// through the supported configuration path; CGS indices fall back to the
    /// private call inside the same transaction.
    public static func apply(mode: DisplayModeInfo, to display: CGDirectDisplayID) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            throw ModeServiceError.configurationFailed("无法开始显示器配置事务。")
        }
        defer { CGCompleteDisplayConfiguration(config, .permanently) }

        if let cgsIndex = mode.cgsIndex {
            let status = CGSConfigureDisplayMode(config, display, Int32(cgsIndex))
            guard status == .success else {
                throw ModeServiceError.configurationFailed("CGSConfigureDisplayMode 失败（\(status.rawValue)）。")
            }
            return
        }

        guard let cgMode = publicMode(matching: mode, for: display) else {
            throw ModeServiceError.modeMissing(mode)
        }
        let status = CGConfigureDisplayWithDisplayMode(config, display, cgMode, nil)
        guard status == .success else {
            throw ModeServiceError.configurationFailed("CGConfigureDisplayWithDisplayMode 失败（\(status.rawValue)）。")
        }
    }
}

public enum ModeServiceError: LocalizedError {
    case configurationFailed(String)
    case modeMissing(DisplayModeInfo)

    public var errorDescription: String? {
        switch self {
        case .configurationFailed(let message):
            return message
        case .modeMissing(let mode):
            return "找不到模式 \(mode.label) 对应的显示模式。"
        }
    }
}
