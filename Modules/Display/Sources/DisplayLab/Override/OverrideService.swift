import AppKit
import DisplayCore
import PrivilegedSupport
import MeridianLocalization

/// Authenticated local requests; no privileged writes into a user's home.
final class OverrideService {
    enum OverrideError: LocalizedError {
        case helperRejected(String)
        var errorDescription: String? {
            if case .helperRejected(let message) = self { return Self.localized(message) }
            return nil
        }

        /// The root helper can't see the app's language setting and always
        /// replies in Chinese; map its fixed replies here.
        private static func localized(_ message: String) -> String {
            guard !Localization.isChinese else { return message }
            let known: [String: String] = [
                "非法的显示器标识。": "Invalid display identifier.",
                "缺少 scale-resolutions 数据。": "Missing scale-resolutions data.",
                "scale-resolutions 数据非法。": "Invalid scale-resolutions data.",
                "显示器参数非法。": "Invalid display parameters.",
                "本来就没有覆盖。": "No override was installed.",
                "覆盖目录不是普通目录，已取消。": "The override location isn't a regular directory; cancelled.",
                "已移除。": "Removed.",
                "未知命令。": "Unknown command.",
            ]
            if let english = known[message] { return english }
            if message.hasPrefix("已写入 ") { return "Wrote " + message.dropFirst(4) }
            return message
        }
    }
    static let daemonLabel = "app.meridian.display.helper"
    static let installedHelperPath = "/Library/PrivilegedHelperTools/app.meridian.display.helper"
    private var installer: HelperInstallation { HelperInstallation(label: Self.daemonLabel, bundledRelativePath: "Contents/MacOS/DisplayLabHelper") }
    var isInstalled: Bool { installer.isInstalled }
    var needsUpdate: Bool { installer.needsUpdate }
    func install() throws { try installer.install() }
    func uninstall() throws { try installer.uninstall() }

    private func send(_ command: HelperCommand) async throws -> HelperResult {
        try await Task.detached(priority: .userInitiated) {
            let data = try JSONEncoder().encode(command)
            let response = try HelperSocket.request(data, label: Self.daemonLabel)
            let result = try JSONDecoder().decode(HelperResult.self, from: response)
            guard result.id == command.id, result.ok else { throw OverrideError.helperRejected(result.message) }
            return result
        }.value
    }

    /// Installs the HiDPI override for a display: a same-aspect HiDPI ladder
    /// (see OverrideSupport.hiDPILadder).
    func installOverride(for display: DisplayInfo) async throws -> String {
        let info = CoreDisplayBridge.createInfoDictionary(for: display.identifier)
        let nativeWidth = info?["kCGDisplayPixelWidth"] as? Int ?? display.pixelWidth / max(1, Int(display.scale))
        let nativeHeight = info?["kCGDisplayPixelHeight"] as? Int ?? display.pixelHeight / max(1, Int(display.scale))
        let widthMM = info?["DisplayHorizontalImageSize"] as? Int ?? 600

        let blobs = OverrideSupport.defaultScaleResolutions(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let ppmm = OverrideSupport.targetDefaultPPMM(nativeWidth: nativeWidth, widthMillimetres: widthMM)

        let command = HelperCommand(
            id: UUID().uuidString,
            action: "write",
            vendorID: display.vendorID,
            productID: display.productID,
            productName: display.name,
            scaleResolutions: blobs.map { $0.base64EncodedString() },
            targetDefaultPPMM: ppmm
        )
        _ = try await send(command)
        let tiers = OverrideSupport.hiDPILadder(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
            .map { "\($0.width)×\($0.height)" }.joined(separator: L("、", ", "))
        return L("已为 \(display.name) 写入 HiDPI 档位：\(tiers)。重新插拔显示线或注销重登后生效。", "Wrote HiDPI tiers for \(display.name): \(tiers). Reconnect the display cable or log out and back in to apply.")
    }

    func removeOverride(for display: DisplayInfo) async throws -> String {
        let command = HelperCommand(
            id: UUID().uuidString,
            action: "remove",
            vendorID: display.vendorID,
            productID: display.productID,
            productName: nil,
            scaleResolutions: nil,
            targetDefaultPPMM: nil
        )
        _ = try await send(command)
        return L("已移除 \(display.name) 的 HiDPI 覆盖。重新插拔显示线或注销重登后恢复。", "Removed the HiDPI override for \(display.name). Reconnect the display cable or log out and back in to revert.")
    }
}
