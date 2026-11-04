import DisplayCore
import Foundation

func mode(_ pixel: (Int, Int), point: (Int, Int), hz: Double, hiDPI: Bool, current: Bool = false) -> DisplayModeInfo {
    DisplayModeInfo(pixelWidth: pixel.0, pixelHeight: pixel.1, pointWidth: point.0, pointHeight: point.1,
                    refreshRate: hz, isHiDPI: hiDPI, cgsIndex: nil, isCurrent: current)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

// 真实链路 timing 是像素==点数、非 HiDPI 的模式。
let carriers = [
    mode((5120, 2880), point: (5120, 2880), hz: 60, hiDPI: false),
    mode((2560, 1440), point: (2560, 1440), hz: 60, hiDPI: false),
]
expect(ModeValidation.carrierTimings(in: carriers).count == 2, "carriers")
expect(ModeValidation.carrierTimings(in: [mode((5120, 2880), point: (2560, 1440), hz: 60, hiDPI: true)]).isEmpty,
       "HiDPI mode is not a carrier")

// 同比例同刷新率才算可渲染；借位模式（同刷新率下无同比例 timing）要被挡掉。
let hiDPICurrent = mode((5120, 2880), point: (2560, 1440), hz: 60, hiDPI: true)
expect(ModeValidation.isRenderable(hiDPICurrent, in: carriers), "HiDPI 60Hz has a carrier")
expect(!ModeValidation.isRenderable(mode((5120, 2880), point: (2560, 1440), hz: 75, hiDPI: true), in: carriers),
       "75Hz has no same-ratio carrier")
expect(!ModeValidation.isRenderable(mode((2560, 1600), point: (2560, 1600), hz: 60, hiDPI: false), in: carriers),
       "16:10 has no 16:9 carrier")
let noCarrier = [mode((5120, 2880), point: (2560, 1440), hz: 60, hiDPI: true)]
expect(ModeValidation.usableModes(in: noCarrier).count == 1, "no carriers means no filtering")

// usableModes 保留当前模式，即使它本身是借位模式。
let borrowedCurrent = mode((5120, 2880), point: (2560, 1440), hz: 75, hiDPI: true, current: true)
let filtered = ModeValidation.usableModes(in: carriers + [borrowedCurrent, mode((2560, 1440), point: (1280, 720), hz: 60, hiDPI: true)])
expect(filtered.contains { $0.refreshRate == 75 && $0.isCurrent }, "current mode kept")
expect(filtered.contains { $0.pointWidth == 1280 }, "renderable HiDPI mode kept")

// 宽高比容差 2%：1.7778 与 1.7786 视为同比例，1.6 不算。
let nearRatio = [mode((2560, 1440), point: (2560, 1440), hz: 60, hiDPI: false)]
expect(ModeValidation.isRenderable(mode((3840, 2160), point: (1920, 1080), hz: 60, hiDPI: true), in: nearRatio),
       "16:9 pair within tolerance")
expect(!ModeValidation.isRenderable(mode((2560, 1600), point: (1280, 800), hz: 60, hiDPI: true), in: nearRatio),
       "16:10 against 16:9 rejected")

// 覆盖文件路径与 hex 编码。
expect(OverrideSupport.overridePath(vendorID: 0x5E3, productID: 0x2702)
        == "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-5e3/DisplayProductID-2702",
       "override path")
expect(OverrideSupport.vendorDirectory(vendorID: 0x10AC) == "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-10ac",
       "vendor directory")

// HiDPI 档位：同比例、宽度不超上限、无重复。
let ladder = OverrideSupport.hiDPILadder(nativeWidth: 5120, nativeHeight: 2880)
expect(!ladder.isEmpty, "ladder is not empty")
expect(ladder.allSatisfy { $0.width * 2 <= OverrideSupport.maxHiDPIPixelWidth }, "ladder within limit")
expect(Set(ladder.map(\.width)).count == ladder.count, "ladder widths unique")
expect(ladder.allSatisfy { abs(Double($0.width) / Double($0.height) - 5120.0 / 2880.0) < 0.01 }, "ladder aspect")
expect(OverrideSupport.hiDPILadder(nativeWidth: 0, nativeHeight: 100).isEmpty, "invalid native size")

let blobs = OverrideSupport.defaultScaleResolutions(nativeWidth: 2560, nativeHeight: 1440)
expect(blobs.count == OverrideSupport.hiDPILadder(nativeWidth: 2560, nativeHeight: 1440).count, "blob count")
expect(blobs.allSatisfy { $0.count == 16 }, "HiDPI blobs are 16 bytes")
expect(OverrideSupport.scaleResolutionBlob(pixelWidth: 2560, pixelHeight: 1440, hiDPI: false).count == 8, "non-HiDPI blob")
expect(OverrideSupport.scaleResolutionBlob(pixelWidth: 2560, pixelHeight: 1440, hiDPI: false)
        == Data([0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x05, 0xA0]), "big-endian width/height")
expect(OverrideSupport.scaleResolutionBlob(pixelWidth: 5120, pixelHeight: 2880, hiDPI: true)
        == Data([0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x0B, 0x40, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]),
       "HiDPI blob layout")

expect(OverrideSupport.validateScaleResolutions(blobs), "valid blobs accepted")
expect(!OverrideSupport.validateScaleResolutions([]), "empty rejected")
expect(!OverrideSupport.validateScaleResolutions([Data(repeating: 0, count: 7)]), "odd size rejected")
expect(!OverrideSupport.validateScaleResolutions([Data(repeating: 0, count: 8)] + Array(repeating: Data(repeating: 0, count: 8), count: 64)),
       "more than 64 rejected")

// 物理尺寸换算 ppmm。
expect(abs(OverrideSupport.targetDefaultPPMM(nativeWidth: 5120, widthMillimetres: 1194) - 5120.0 / 1194.0) < 0.0001, "ppmm")
expect(OverrideSupport.targetDefaultPPMM(nativeWidth: 5120, widthMillimetres: 0) == 4.27, "ppmm fallback")

print("DisplayCoreSmoke ok")
