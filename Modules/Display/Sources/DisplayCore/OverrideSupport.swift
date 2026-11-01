import Foundation

/// Shared override-plist helpers: path derivation, scale-resolutions blob
/// encoding and ppmm math. The app uses them to build a preview and the
/// helper re-validates everything it receives before touching the filesystem.
public enum OverrideSupport {
    /// /Library/Displays/Contents/Resources/Overrides — the user-level
    /// override root that WindowServer reads on display attach (works with
    /// SIP enabled; the System copy is the read-only fallback).
    public static let overridesRoot = "/Library/Displays/Contents/Resources/Overrides"

    /// Directory for one display, e.g. .../Overrides/DisplayVendorID-5e3.
    public static func vendorDirectory(vendorID: UInt32) -> String {
        "\(overridesRoot)/DisplayVendorID-\(String(vendorID, radix: 16))"
    }

    /// Plist file for one display, e.g. .../DisplayVendorID-5e3/DisplayProductID-2702.
    public static func overridePath(vendorID: UInt32, productID: UInt32) -> String {
        "\(vendorDirectory(vendorID: vendorID))/DisplayProductID-\(String(productID, radix: 16))"
    }

    /// Encodes one scale-resolutions entry. HiDPI entries are 16 bytes:
    /// big-endian uint32 width, height, flags (1 = HiDPI), scale (16.16
    /// fixed point 1.0). Non-HiDPI entries are 8 bytes: width, height.
    public static func scaleResolutionBlob(pixelWidth: Int, pixelHeight: Int, hiDPI: Bool) -> Data {
        var data = Data()
        func appendBEUInt32(_ value: UInt32) {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        appendBEUInt32(UInt32(pixelWidth))
        appendBEUInt32(UInt32(pixelHeight))
        if hiDPI {
            appendBEUInt32(1)          // flags: HiDPI
            appendBEUInt32(0x00010000) // scale: 1.0 in 16.16 fixed point
        }
        return data
    }

    /// 平滑缩放档位相对面板原生宽度的比例（与 BetterDisplay 的 flexible scaling 同思路：
    /// 只要同宽高比的 HiDPI 档，不要一堆低分辨率模式）。
    public static let hiDPIScaleSteps: [Double] = [0.5, 0.625, 0.75, 0.8, 0.9, 1.0, 1.125]

    /// HiDPI 帧缓冲宽度上限。Apple 芯片对缩放模式的最大源宽度约 6K（Pro Display XDR
    /// 的 3008×1692 HiDPI 即 6016 像素宽），超过的档位系统会忽略或渲染异常。
    public static let maxHiDPIPixelWidth = 6144

    /// 一组同宽高比的 HiDPI 档位，返回桌面点数，从小到大。
    public static func hiDPILadder(nativeWidth: Int, nativeHeight: Int) -> [(width: Int, height: Int)] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        var seen = Set<Int>()
        return hiDPIScaleSteps.compactMap { step in
            let width = Int((Double(nativeWidth) * step / 2).rounded()) * 2
            let height = Int((Double(width) * Double(nativeHeight) / Double(nativeWidth) / 2).rounded()) * 2
            guard width * 2 <= maxHiDPIPixelWidth, seen.insert(width).inserted else { return nil }
            return (width, height)
        }
    }

    /// Builds the HiDPI resolution set written to the override plist. Entries
    /// are framebuffer pixels (2× the desktop size) flagged as HiDPI.
    public static func defaultScaleResolutions(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        hiDPILadder(nativeWidth: nativeWidth, nativeHeight: nativeHeight).map {
            scaleResolutionBlob(pixelWidth: $0.width * 2, pixelHeight: $0.height * 2, hiDPI: true)
        }
    }

    /// 读取已安装的覆盖文件里的 scale-resolutions（文件对所有用户可读，不需要助手）。
    /// 兼容顶层与 DisplayResolutionEnabled 字典两种写法；文件不存在时返回 nil。
    public static func installedScaleResolutions(vendorID: UInt32, productID: UInt32) -> [Data]? {
        let path = overridePath(vendorID: vendorID, productID: productID)
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        if let blobs = plist["scale-resolutions"] as? [Data] { return blobs }
        if let nested = plist["DisplayResolutionEnabled"] as? [String: Any],
           let blobs = nested["scale-resolutions"] as? [Data] {
            return blobs
        }
        return []
    }

    /// Pixels per millimetre from the display's physical size; WindowServer
    /// uses this to pick the default scaled mode.
    public static func targetDefaultPPMM(nativeWidth: Int, widthMillimetres: Int) -> Double {
        guard widthMillimetres > 0 else { return 4.27 }
        return Double(nativeWidth) / Double(widthMillimetres)
    }

    /// Sanity checks applied to client-supplied override payloads before the
    /// helper writes anything.
    public static func validateScaleResolutions(_ blobs: [Data]) -> Bool {
        guard !blobs.isEmpty, blobs.count <= 64 else { return false }
        return blobs.allSatisfy { blob in
            blob.count == 8 || blob.count == 12 || blob.count == 16
        }
    }
}
