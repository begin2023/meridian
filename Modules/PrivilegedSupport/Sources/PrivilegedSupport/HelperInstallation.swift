import Foundation
import Security
import CryptoKit
import Darwin
import MeridianLocalization

public struct HelperConfiguration: Codable {
    public let requirement: String
    public let uid: uid_t
    public let gid: gid_t
    public let appPath: String

    public static func load(label: String) throws -> HelperConfiguration {
        let path = HelperInstallation.directory + "/\(label).json"
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HelperFailure.rejected(L("助手配置不存在。", "Helper configuration not found.")) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == 0, st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o022 == 0, st.st_size > 0, st.st_size <= 16384 else { throw HelperFailure.rejected(L("不安全的助手配置。", "Unsafe helper configuration.")) }
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw HelperFailure.rejected(L("助手配置不完整。", "Incomplete helper configuration.")) }
        let config = try JSONDecoder().decode(Self.self, from: Data(bytes))
        guard config.uid > 0, config.gid > 0, config.requirement.count < 2048 else { throw HelperFailure.rejected(L("无效的助手配置。", "Invalid helper configuration.")) }
        return config
    }

    /// The helper keeps running only while an app signed by the installing
    /// identity still sits at the recorded path.
    public var applicationExists: Bool {
        guard appPath.hasPrefix("/"),
              appPath == URL(fileURLWithPath: appPath).standardizedFileURL.path,
              appPath == URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path,
              let bundle = Bundle(path: appPath), bundle.bundleIdentifier == "app.meridian.control",
              FileManager.default.isExecutableFile(atPath: appPath + "/Contents/MacOS/Meridian") else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        return (try? secRequirement()).map { SecStaticCodeCheckValidity(code, [], $0) == errSecSuccess } ?? false
    }

    private func secRequirement() throws -> SecRequirement {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else {
            throw HelperFailure.rejected(L("助手配置中的签名要求无效。", "Invalid code signing requirement in the helper configuration."))
        }
        return parsed
    }
}

public struct HelperInstallation {
    public static let directory = "/Library/PrivilegedHelperTools"
    public let label: String
    public let bundledRelativePath: String
    public init(label: String, bundledRelativePath: String) { self.label = label; self.bundledRelativePath = bundledRelativePath }
    public var installedPath: String { Self.directory + "/" + label }
    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: installedPath) }
    private var bundledURL: URL { Bundle.main.bundleURL.appendingPathComponent(bundledRelativePath) }
    public var needsUpdate: Bool {
        guard isInstalled else { return false }
        guard let bundled = try? Data(contentsOf: bundledURL), let installed = try? Data(contentsOf: URL(fileURLWithPath: installedPath)),
              let config = try? HelperConfiguration.load(label: label), config.uid == getuid(), config.gid == getgid(), config.appPath == Bundle.main.bundleURL.standardizedFileURL.path,
              let requirement = try? Self.clientRequirement(), config.requirement == requirement else { return true }
        return bundled != installed
    }

    private static func clientRequirement() throws -> String {
        var code: SecCode?; var staticCode: SecStaticCode?; var requirement: SecRequirement?; var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { throw HelperFailure.rejected(L("请从签名的 Meridian.app 安装助手。", "Install the helper from a signed Meridian.app.")) }
        guard Bundle.main.bundleIdentifier == "app.meridian.control" else { throw HelperFailure.rejected(L("只有 Meridian.app 可以安装助手。", "Only Meridian.app can install the helper.")) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32, flags & 0x10000 != 0 else { throw HelperFailure.rejected(L("应用需要启用 hardened runtime 后才能安装助手。", "The app needs the hardened runtime enabled to install the helper.")) }
        return text as String
    }

    public func install() throws {
        precondition(!Thread.isMainThread, "Authorization must not block the UI")
        let label = try checkedLabel()
        let config = HelperConfiguration(requirement: try Self.clientRequirement(), uid: getuid(), gid: getgid(), appPath: Bundle.main.bundleURL.standardizedFileURL.path)
        let configData = try JSONEncoder().encode(config)
        let source = try Data(contentsOf: bundledURL)
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let plist: [String: Any] = ["Label": label, "Program": installedPath, "ProgramArguments": [installedPath], "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10, "ProcessType": "Background"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let legacy = label == Self.thermalDaemonLabel
            ? ["/Library/LaunchDaemons/\(Self.legacyThermalLabel).plist", "/Library/PrivilegedHelperTools/\(Self.legacyThermalLabel)"].map(Self.quote).joined(separator: " ")
            : ""
        let legacyCleanup = legacy.isEmpty ? "" : """
        /bin/launchctl bootout system/\(Self.legacyThermalLabel) 2>/dev/null || true
        for old in \(legacy); do check_file "$old" || exit 1; done
        /bin/rm -f \(legacy)
        """
        let shell = """
        set -eu
        \(Self.shellGuards)
        check_dir /Library
        check_dir /Library/PrivilegedHelperTools
        check_dir /Library/LaunchDaemons
        helper=\(Self.quote(installedPath))
        config=\(Self.quote(installedPath + ".json"))
        plist=\(Self.quote("/Library/LaunchDaemons/\(label).plist"))
        for target in "$helper" "$config" "$plist"; do check_file "$target" || exit 1; done
        stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.meridian-install.XXXXXX)
        trap '/bin/rm -rf "${stage:?}"' EXIT
        /bin/cp \(Self.quote(bundledURL.path)) "$stage/helper"
        [ "$(/usr/bin/shasum -a 256 "$stage/helper" | /usr/bin/cut -d ' ' -f 1)" = \(Self.quote(digest)) ] || exit 1
        /usr/bin/printf '%s' \(Self.quote(configData.base64EncodedString())) | /usr/bin/base64 -D > "$stage/config"
        /usr/bin/printf '%s' \(Self.quote(plistData.base64EncodedString())) | /usr/bin/base64 -D > "$stage/plist"
        /usr/sbin/chown root:wheel "$stage/helper" "$stage/config" "$stage/plist"
        /bin/chmod 755 "$stage/helper"
        /bin/chmod 644 "$stage/config" "$stage/plist"
        /bin/mkdir "$stage/backup"
        [ ! -e "$helper" ] || /bin/cp -p "$helper" "$stage/backup/helper"
        [ ! -e "$config" ] || /bin/cp -p "$config" "$stage/backup/config"
        [ ! -e "$plist" ] || /bin/cp -p "$plist" "$stage/backup/plist"
        rollback() {
          for name in helper config plist; do
            eval "target=\\$$name"
            if [ -e "$stage/backup/$name" ]; then /bin/cp -p "$stage/backup/$name" "$target"; else /bin/rm -f "$target"; fi
          done
          /bin/launchctl bootstrap system "$plist" 2>/dev/null || true
        }
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        { /bin/mv -f "$stage/helper" "$helper" && /bin/mv -f "$stage/config" "$config" && /bin/mv -f "$stage/plist" "$plist"; } || { rollback; exit 1; }
        /bin/launchctl bootstrap system "$plist" || { rollback; exit 1; }
        \(legacyCleanup)
        """
        try Self.authorize(shell)
    }

    public func uninstall() throws {
        precondition(!Thread.isMainThread, "Authorization must not block the UI")
        let label = try checkedLabel()
        let socket = HelperSocket.path(label)
        try Self.authorize("""
        set -eu
        \(Self.shellGuards)
        helper=\(Self.quote(installedPath))
        config=\(Self.quote(installedPath + ".json"))
        plist=\(Self.quote("/Library/LaunchDaemons/\(label).plist"))
        for target in "$helper" "$config" "$plist"; do check_file "$target" || exit 1; done
        if [ -e \(Self.quote(socket)) ] || [ -L \(Self.quote(socket)) ]; then
          owner=$(/usr/bin/stat -f %u \(Self.quote(socket)))
          [ -S \(Self.quote(socket)) ] && [ ! -L \(Self.quote(socket)) ] && { [ "$owner" = 0 ] || [ "$owner" = \(getuid()) ]; } || exit 1
        fi
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/rm -f "$plist" "$helper" "$config" \(Self.quote(socket))
        """)
    }

    private func checkedLabel() throws -> String {
        guard label.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { throw HelperFailure.rejected(L("助手标识非法。", "Invalid helper label.")) }
        return label
    }

    private static let legacyThermalLabel = "app.meridian.thermal.helper"
    /// 清理早期文件协议版本应发生在安装 thermal daemon 时，而不是安装 legacy 标签本身。
    private static let thermalDaemonLabel = "app.meridian.thermal.daemon"

    private static let shellGuards = """
    check_dir() {
      [ -d "$1" ] && [ ! -L "$1" ] || return 1
      [ "$(/usr/bin/stat -f %u:%g "$1")" = 0:0 ] || return 1
      /usr/bin/find "$1" -prune -perm +022 -print | /usr/bin/grep -q . && return 1
      return 0
    }
    check_file() {
      [ -e "$1" ] || [ -L "$1" ] || return 0
      [ -f "$1" ] && [ ! -L "$1" ] || return 1
      [ "$(/usr/bin/stat -f %u:%g "$1")" = 0:0 ] || return 1
      [ "$(/usr/bin/stat -f %l "$1")" = 1 ] || return 1
      /usr/bin/find "$1" -prune -perm +022 -print | /usr/bin/grep -q . && return 1
      return 0
    }
    """

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func authorize(_ shell: String) throws {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        // No pipe can fill while waiting for authorization.
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
            throw HelperFailure.rejected(L("管理员授权超过 60 秒，已取消等待；请检查助手状态后重试。", "Administrator authorization took longer than 60 seconds and was abandoned. Check the helper status and try again."))
        }
        guard task.terminationStatus == 0 else { throw HelperFailure.rejected(L("管理员授权被取消或助手安装失败。", "Administrator authorization was canceled or the helper installation failed.")) }
    }
}
