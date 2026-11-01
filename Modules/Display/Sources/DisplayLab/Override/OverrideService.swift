import AppKit
import Darwin
import DisplayCore
import Foundation

/// App-side driver for the privileged helper. On this machine, ad-hoc signed
/// apps cannot open XPC connections to system daemons (the same 4097 failure
/// FanControlLab hit), so installation goes through an osascript admin flow
/// and commands travel over a polled file protocol.
final class OverrideService {
    enum OverrideError: LocalizedError {
        case daemonNotInstalled
        case commandTimeout
        case authorizationTimeout
        case helperRejected(String)

        var errorDescription: String? {
            switch self {
            case .daemonNotInstalled:
                return "特权助手未安装，请先在偏好设置里安装。"
            case .commandTimeout:
                return "助手没有响应（超时）。"
            case .authorizationTimeout:
                return "管理员授权流程超过 60 秒，已终止本次操作。"
            case .helperRejected(let message):
                return message
            }
        }
    }

    static let daemonLabel = "app.meridian.display.helper"
    static let installedHelperPath = "/Library/PrivilegedHelperTools/app.meridian.display.helper"

    private let commandURL: URL
    private let resultURL: URL
    private let queue = DispatchQueue(label: "app.meridian.display.override", qos: .userInitiated)

    init() {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DisplayLab")
        commandURL = base.appendingPathComponent("helper-command.json")
        resultURL = base.appendingPathComponent("helper-result.json")
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.installedHelperPath)
    }

    /// Command file handed to the daemon as argv[1] at install time.
    var commandFilePath: String {
        commandURL.path
    }

    // MARK: - Install / uninstall

    /// Installs the daemon with an administrator authorization dialog.
    func install() throws {
        guard let template = Bundle.main.url(forResource: "helper-launchd", withExtension: "plist") else {
            throw OverrideError.helperRejected("缺少 helper-launchd.plist 模板（请用 make app 重新构建）。")
        }
        guard let templateText = try? String(contentsOf: template, encoding: .utf8) else {
            throw OverrideError.helperRejected("读取 launchd 模板失败。")
        }

        try FileManager.default.createDirectory(at: commandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helperSource = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/DisplayLabHelper").path
        let plistText = templateText
            .replacingOccurrences(of: "@HELPER_PATH@", with: Self.installedHelperPath)
            .replacingOccurrences(of: "@COMMAND_FILE@", with: commandURL.path)
        let temporaryPlist = NSTemporaryDirectory() + "\(Self.daemonLabel).plist"
        try plistText.write(toFile: temporaryPlist, atomically: true, encoding: .utf8)

        func quoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let shell = """
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || true
        sleep 1
        cp \(quoted(helperSource)) \(quoted(Self.installedHelperPath))
        chown root:wheel \(quoted(Self.installedHelperPath))
        chmod 755 \(quoted(Self.installedHelperPath))
        cp \(quoted(temporaryPlist)) /Library/LaunchDaemons/\(Self.daemonLabel).plist
        chown root:wheel /Library/LaunchDaemons/\(Self.daemonLabel).plist
        chmod 644 /Library/LaunchDaemons/\(Self.daemonLabel).plist
        launchctl bootstrap system /Library/LaunchDaemons/\(Self.daemonLabel).plist
        """
        try runWithAdminPrivileges(shell)
    }

    func uninstall() throws {
        let shell = """
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || true
        rm -f /Library/LaunchDaemons/\(Self.daemonLabel).plist \(Self.installedHelperPath)
        """
        try runWithAdminPrivileges(shell)
    }

    /// Runs the shell through a separate osascript process; an in-process
    /// NSAppleScript can hang in some scenarios (same workaround as
    /// FanControlLab).
    private func runWithAdminPrivileges(_ shell: String) throws {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw OverrideError.helperRejected("无法启动授权流程：\(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            try? stderrPipe.fileHandleForReading.close()
            throw OverrideError.authorizationTimeout
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw OverrideError.helperRejected("安装被取消或失败：\(stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr)")
        }
    }

    // MARK: - File protocol commands

    private func send(_ command: HelperCommand) throws -> HelperResult {
        guard isInstalled else {
            throw OverrideError.daemonNotInstalled
        }
        return try queue.sync {
            // Clear any stale result so a matching id is meaningful.
            try? FileManager.default.removeItem(at: resultURL)
            let encoder = JSONEncoder()
            let data = try encoder.encode(command)
            try data.write(to: commandURL, options: .atomic)

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let resultData = try? Data(contentsOf: resultURL),
                   let result = try? JSONDecoder().decode(HelperResult.self, from: resultData),
                   result.id == command.id {
                    guard result.ok else {
                        throw OverrideError.helperRejected(result.message)
                    }
                    return result
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw OverrideError.commandTimeout
        }
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
        _ = try send(command)
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
        _ = try send(command)
        return "已移除 \(display.name) 的 HiDPI 覆盖。重新插拔显示线或注销重登后恢复。"
    }

    func installedOverrides() async -> [String] {
        guard let result = try? send(HelperCommand(
            id: UUID().uuidString,
            action: "list",
            vendorID: nil,
            productID: nil,
            productName: nil,
            scaleResolutions: nil,
            targetDefaultPPMM: nil
        )) else {
            return []
        }
        return result.overrides ?? []
    }
}
