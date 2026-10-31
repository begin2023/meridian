import AppKit
import DisplayCore
import Foundation

/// Builds the JSON display report consumed by the smoke tests. Written to
/// /tmp/displaylab-display-report.json when the app runs with
/// --display-report.
enum DisplayReportBuilder {
    struct DisplayReport: Encodable {
        struct ModeCounts: Encodable {
            let total: Int
            let hidpi: Int
            let cgs: Int
            let publicModes: Int
        }

        struct DDCReport: Encodable {
            let serviceMatched: Bool
            let edidVendor: Int?
            let edidProduct: Int?
            let luminance: DDCDevice.VCPValue?
            let error: String?
        }

        struct ModeReport: Encodable {
            let label: String
            let width: Int
            let height: Int
            let refreshRate: Double
            let isHiDPI: Bool
            let cgsIndex: Int?
        }

        let identifier: CGDirectDisplayID
        let name: String
        let vendorID: Int
        let productID: Int
        let isBuiltIn: Bool
        let isVirtual: Bool
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: Double
        let modeCounts: ModeCounts
        let modes: [ModeReport]
        let ddc: DDCReport
    }

    struct Report: Encodable {
        let generatedAt: Date
        let displays: [DisplayReport]
    }

    static func build(manager: DisplayManager, probeDDC: Bool) -> Report {
        let displays = manager.displays.map { display -> DisplayReport in
            let counts = DisplayReport.ModeCounts(
                total: display.modes.count,
                hidpi: display.modes.filter { $0.isHiDPI }.count,
                cgs: display.modes.filter { $0.cgsIndex != nil }.count,
                publicModes: display.modes.filter { $0.cgsIndex == nil }.count
            )
            let modes = display.sortedModes.prefix(24).map { mode in
                DisplayReport.ModeReport(
                    label: mode.label,
                    width: mode.pixelWidth,
                    height: mode.pixelHeight,
                    refreshRate: mode.refreshRate,
                    isHiDPI: mode.isHiDPI,
                    cgsIndex: mode.cgsIndex
                )
            }

            var ddcReport = DisplayReport.DDCReport(
                serviceMatched: false,
                edidVendor: nil,
                edidProduct: nil,
                luminance: nil,
                error: nil
            )
            if probeDDC {
                do {
                    let service = try AVServiceLocator.avService(for: display.identifier)
                    let device = DDCDevice(displayID: display.identifier, service: service)
                    let luminance = try? device.readLuminance()
                    ddcReport = DisplayReport.DDCReport(
                        serviceMatched: true,
                        edidVendor: Int(display.vendorID),
                        edidProduct: Int(display.productID),
                        luminance: luminance,
                        error: luminance == nil ? "DDC 读取失败" : nil
                    )
                } catch {
                    ddcReport = DisplayReport.DDCReport(
                        serviceMatched: false,
                        edidVendor: nil,
                        edidProduct: nil,
                        luminance: nil,
                        error: error.localizedDescription
                    )
                }
            }

            return DisplayReport(
                identifier: display.identifier,
                name: display.name,
                vendorID: Int(display.vendorID),
                productID: Int(display.productID),
                isBuiltIn: display.isBuiltIn,
                isVirtual: display.isVirtual,
                pixelWidth: display.pixelWidth,
                pixelHeight: display.pixelHeight,
                scale: Double(display.scale),
                modeCounts: counts,
                modes: Array(modes),
                ddc: ddcReport
            )
        }
        return Report(generatedAt: Date(), displays: displays)
    }
}
