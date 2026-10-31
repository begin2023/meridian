import AppKit
import CoreGraphics
import DisplayPrivate

/// One selectable display mode. `cgsIndex` refers to the private CGS mode
/// table; modes discovered through the public API carry nil and switch through
/// CGConfigureDisplayWithDisplayMode instead.
public struct DisplayModeInfo: Equatable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let isHiDPI: Bool
    public let cgsIndex: Int?
    public let isCurrent: Bool

    public var label: String {
        let hidpiMark = isHiDPI ? " HiDPI" : ""
        let frequency = refreshRate > 0 ? String(format: " @ %.0fHz", refreshRate) : ""
        return "\(pixelWidth)×\(pixelHeight)\(hidpiMark)\(frequency)"
    }

    /// Pixel-to-point ratio used to classify HiDPI modes when the SDK lacks
    /// CGDisplayModeIsHiDPI. A backing scale of 2.0 (or 1.5) marks HiDPI.
    public static func ratio(_ pixel: Int, _ points: Int) -> Double {
        points > 0 ? Double(pixel) / Double(points) : 1
    }
}

/// Static description of one connected display.
public struct DisplayInfo {
    public let identifier: CGDirectDisplayID
    public let name: String
    public let vendorID: UInt32
    public let productID: UInt32
    public let isBuiltIn: Bool
    public let isVirtual: Bool
    public let bounds: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: CGFloat
    public let modes: [DisplayModeInfo]
    public let currentMode: DisplayModeInfo?

    /// HiDPI modes only, ordered by pixel width then refresh rate.
    public var hidpiModes: [DisplayModeInfo] {
        modes
            .filter { $0.isHiDPI }
            .sorted { lhs, rhs in
                if lhs.pixelWidth != rhs.pixelWidth {
                    return lhs.pixelWidth > rhs.pixelWidth
                }
                return lhs.refreshRate > rhs.refreshRate
            }
    }

    /// All modes including low resolution variants, ordered for menu display.
    public var sortedModes: [DisplayModeInfo] {
        modes
            .sorted { lhs, rhs in
                if lhs.pixelWidth != rhs.pixelWidth {
                    return lhs.pixelWidth > rhs.pixelWidth
                }
                if lhs.pixelHeight != rhs.pixelHeight {
                    return lhs.pixelHeight > rhs.pixelHeight
                }
                return lhs.refreshRate > rhs.refreshRate
            }
    }
}

public enum DisplayEnumerationError: LocalizedError {
    case unresolvedName(CGDirectDisplayID)

    public var errorDescription: String? {
        switch self {
        case .unresolvedName(let identifier):
            return "无法确定显示器 \(identifier) 的名称。"
        }
    }
}

public enum DisplayEnumerator {
    /// Enumerates every active display with its modes. CGS enumeration runs
    /// first because it also exposes modes WindowServer hides from the public
    /// list; public modes fill in anything CGS fails to describe.
    public static func enumerate() throws -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else {
            return []
        }

        var result = identifiers.prefix(Int(count)).map { display in
            describe(display: display)
        }
        // 硬件镜像的从属屏（例如 5K 上采样时镜像虚拟屏的物理面板）不在活动列表里，
        // 但仍需出现在界面上，才能调亮度或关闭上采样。
        var onlineCount: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &onlineCount) == .success, onlineCount > 0 {
            var online = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
            if CGGetOnlineDisplayList(onlineCount, &online, &onlineCount) == .success {
                let active = Set(identifiers.prefix(Int(count)))
                for display in online.prefix(Int(onlineCount))
                    where !active.contains(display) && CGDisplayMirrorsDisplay(display) != kCGNullDirectDisplay {
                    result.append(describe(display: display))
                }
            }
        }
        return result
    }

    public static func describe(display: CGDirectDisplayID) -> DisplayInfo {
        let modes = ModeService.modes(for: display)
        let currentMode = CGDisplayCopyDisplayMode(display)
        let bounds = CGDisplayBounds(display)
        let pixelWidth = currentMode?.pixelWidth ?? Int(bounds.width)
        let pixelHeight = currentMode?.pixelHeight ?? Int(bounds.height)
        let boundsSize = bounds.size
        let scale = boundsSize.width > 0 ? CGFloat(pixelWidth) / boundsSize.width : 1

        return DisplayInfo(
            identifier: display,
            name: displayName(for: display),
            vendorID: CGDisplayVendorNumber(display),
            productID: CGDisplayModelNumber(display),
            isBuiltIn: CGDisplayIsBuiltin(display) != 0,
            isVirtual: CGDisplayModelNumber(display) == 0x76697274,
            bounds: CGDisplayBounds(display),
            pixelWidth: Int(pixelWidth),
            pixelHeight: Int(pixelHeight),
            scale: scale,
            modes: modes,
            currentMode: modes.first(where: { $0.isCurrent })
        )
    }

    /// Friendly display name: NSScreen.localizedName first, CoreDisplay info
    /// dictionary as fallback, final fallback "显示器 <id>".
    public static func displayName(for display: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens where screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display {
            let localized = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !localized.isEmpty {
                return localized
            }
        }

        if let info = CoreDisplayBridge.createInfoDictionary(for: display) {
            // DisplayProductName is a localized dictionary; prefer zh/en.
            if let names = info["DisplayProductName"] as? [String: String] {
                let name = names["zh_CN"] ?? names["en_US"] ?? names.values.first
                if let name, !name.isEmpty {
                    return name
                }
            }
        }

        return "显示器 \(display)"
    }
}

/// Thin wrapper around the private CoreDisplay info dictionary call so the
/// rest of the app does not import DisplayPrivate directly.
public enum CoreDisplayBridge {
    public static func createInfoDictionary(for display: CGDirectDisplayID) -> [String: Any]? {
        guard let unmanaged = CoreDisplay_DisplayCreateInfoDictionary(display) else {
            return nil
        }
        let dictionary = unmanaged.takeRetainedValue()
        return dictionary as NSDictionary as? [String: Any]
    }
}
