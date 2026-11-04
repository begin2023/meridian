import AppKit
import DisplayCore
import PrivilegedSupport

/// Authenticated local requests; no privileged writes into a user's home.
final class OverrideService {
    enum OverrideError: LocalizedError {
        case helperRejected(String)
        var errorDescription: String? { if case .helperRejected(let message) = self { return message }; return nil }
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
            .map { "\($0.width)×\($0.height)" }.joined(separator: "、")
        return "已为 \(display.name) 写入 HiDPI 档位：\(tiers)。重新插拔显示线或注销重登后生效。"
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
        return "已移除 \(display.name) 的 HiDPI 覆盖。重新插拔显示线或注销重登后恢复。"
    }
}
