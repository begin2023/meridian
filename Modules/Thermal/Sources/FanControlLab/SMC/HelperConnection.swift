import AppKit

/// 特权守护进程安装状态与安装/卸载。
///
/// 架构说明：本机 ad-hoc 签名下 XPC 连 system daemon 不通
/// （NSXPCConnection 与底层 XPC 均 4097），控制链路改为文件协议——
/// root 守护进程轮询 desired.json，app 不再需要与助手保持 XPC 连接。
enum HelperInstallStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notSupported
}

final class DaemonInstaller {
    static let daemonLabel = "app.meridian.thermal.daemon"
    static let legacyHelperLabel = "app.meridian.thermal.helper"
    static let installedDaemonPath = "/Library/PrivilegedHelperTools/app.meridian.thermal.daemon"

    /// 用户侧的控制文件路径（daemon 以参数形式收到同一路径）
    var controlFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FanControlLab/desired.json")
    }

    var status: HelperInstallStatus {
        if FileManager.default.isExecutableFile(atPath: Self.installedDaemonPath) {
            return .enabled
        }
        return .notRegistered
    }

    /// 以管理员权限安装守护进程（osascript 标准授权框）。
    /// 同时清理早期版本的 SMJobBless/XPC helper 残留。
    func install() throws {
        // 1. 生成 launchd plist（按本机路径替换占位符）
        guard let template = Bundle.main.url(forResource: "daemon-launchd", withExtension: "plist") else {
            throw NSError(domain: "FanControlLabDaemon", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "缺少 daemon-launchd.plist 模板"])
        }
        guard let templateText = try? String(contentsOf: template, encoding: .utf8) else {
            throw NSError(domain: "FanControlLabDaemon", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "读取 plist 模板失败"])
        }
        let daemonPath = Self.installedDaemonPath
        let plistText = templateText
            .replacingOccurrences(of: "@DAEMON_PATH@", with: daemonPath)
            .replacingOccurrences(of: "@CONTROL_FILE@", with: controlFileURL.path)
        let tmpPlist = NSTemporaryDirectory() + "\(Self.daemonLabel).plist"
        try plistText.write(toFile: tmpPlist, atomically: true, encoding: .utf8)

        // 2. 管理员授权执行安装
        func quoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let shell = """
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        launchctl bootout system/\(Self.legacyHelperLabel) 2>/dev/null || true
        rm -f /Library/LaunchDaemons/\(Self.legacyHelperLabel).plist /Library/PrivilegedHelperTools/\(Self.legacyHelperLabel)
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || true
        sleep 1
        cp \(quoted(Bundle.main.bundleURL.path + "/Contents/Library/LaunchServices/\(Self.daemonLabel)")) \(quoted(daemonPath))
        chown root:wheel \(quoted(daemonPath))
        chmod 755 \(quoted(daemonPath))
        cp \(quoted(tmpPlist)) /Library/LaunchDaemons/\(Self.daemonLabel).plist
        chown root:wheel /Library/LaunchDaemons/\(Self.daemonLabel).plist
        chmod 644 /Library/LaunchDaemons/\(Self.daemonLabel).plist
        launchctl bootstrap system /Library/LaunchDaemons/\(Self.daemonLabel).plist
        """
        try runWithAdminPrivileges(shell)
    }

    func uninstall() throws {
        let shell = """
        launchctl bootout system/\(Self.daemonLabel) 2>/dev/null || true
        rm -f /Library/LaunchDaemons/\(Self.daemonLabel).plist \(Self.installedDaemonPath)
        """
        try runWithAdminPrivileges(shell)
    }

    /// 经独立 osascript 子进程执行（进程内 NSAppleScript 在个别场景会卡死）。
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
            throw NSError(
                domain: "FanControlLabDaemon", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "无法启动授权流程：\(error.localizedDescription)"]
            )
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "FanControlLabDaemon", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "安装被取消或失败：\(stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr)"]
            )
        }
    }
}
