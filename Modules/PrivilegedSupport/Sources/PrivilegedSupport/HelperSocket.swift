import Foundation
import Darwin
import Security
import MeridianLocalization

public enum HelperFailure: LocalizedError {
    case rejected(String)
    public var errorDescription: String? { if case .rejected(let message) = self { return message }; return nil }
}

public enum HelperSocket {
    public static let maximumMessageSize = 65_536
    public static func path(_ label: String) -> String { "/var/run/\(label).sock" }

    private static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw HelperFailure.rejected(L("助手路径过长。", "Helper path is too long.")) }
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { $0.copyBytes(from: bytes) }
        return value
    }

    private static func wait(_ fd: Int32, event: Int16, until deadline: TimeInterval) throws {
        let left = deadline - ProcessInfo.processInfo.systemUptime
        guard left > 0 else { throw HelperFailure.rejected(L("助手连接超时。", "Helper connection timed out.")) }
        var item = pollfd(fd: fd, events: event, revents: 0)
        guard poll(&item, 1, Int32(min(1000, ceil(left * 1000)))) > 0, item.revents & event != 0 else {
            throw HelperFailure.rejected(L("助手连接已关闭或超时。", "Helper connection closed or timed out."))
        }
    }

    private static func transfer(_ fd: Int32, bytes: inout [UInt8], writing: Bool, deadline: TimeInterval) throws {
        var offset = 0
        while offset < bytes.count {
            try wait(fd, event: Int16(writing ? POLLOUT : POLLIN), until: deadline)
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { p -> Int in
                if writing { return Darwin.send(fd, p.baseAddress!.advanced(by: offset), remaining, MSG_DONTWAIT) }
                return recv(fd, p.baseAddress!.advanced(by: offset), remaining, MSG_DONTWAIT)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw HelperFailure.rejected(L("助手消息不完整。", "Incomplete helper message.")) }
            offset += count
        }
    }

    public static func receive(_ fd: Int32, timeout: TimeInterval = 0.25) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + min(1, max(0.01, timeout))
        var header = [UInt8](repeating: 0, count: 4)
        try transfer(fd, bytes: &header, writing: false, deadline: deadline)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= maximumMessageSize else { throw HelperFailure.rejected(L("助手消息大小非法。", "Invalid helper message size.")) }
        var body = [UInt8](repeating: 0, count: size)
        try transfer(fd, bytes: &body, writing: false, deadline: deadline)
        return Data(body)
    }

    public static func send(_ data: Data, to fd: Int32) throws {
        guard !data.isEmpty, data.count <= maximumMessageSize else { throw HelperFailure.rejected(L("助手消息大小非法。", "Invalid helper message size.")) }
        let n = UInt32(data.count)
        var bytes = [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)] + data
        try transfer(fd, bytes: &bytes, writing: true, deadline: ProcessInfo.processInfo.systemUptime + 0.25)
    }

    public static func request(_ data: Data, label: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperFailure.rejected(L("无法连接助手。", "Couldn't connect to the helper.")) }
        defer { close(fd) }
        configure(fd)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var addr = try address(path(label))
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw HelperFailure.rejected(L("助手未运行，请安装或更新助手。", "The helper isn't running. Install or update the helper.")) }
            try wait(fd, event: Int16(POLLOUT), until: ProcessInfo.processInfo.systemUptime + 1)
            var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw HelperFailure.rejected(L("助手连接失败。", "Helper connection failed.")) }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw HelperFailure.rejected(L("拒绝非 root 助手。", "Rejected a helper not running as root.")) }
        try send(data, to: fd)
        return try receive(fd, timeout: 1)
    }

    private static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    public final class Server {
        private let fd: Int32
        private let socketPath: String
        private let requirement: SecRequirement
        private let allowedUID: uid_t
        private let allowedGID: gid_t

        public init(label: String, requirement text: String, allowedUID: uid_t, allowedGID: gid_t) throws {
            guard geteuid() == 0, allowedUID > 0, allowedGID > 0,
                  label.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { throw HelperFailure.rejected(L("助手必须以 root 运行并绑定安装用户。", "The helper must run as root and be bound to the installing user.")) }
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { throw HelperFailure.rejected(L("缺少有效调用方签名要求。", "Missing a valid caller code signing requirement.")) }
            self.requirement = requirement; self.allowedUID = allowedUID; self.allowedGID = allowedGID
            socketPath = HelperSocket.path(label)
            var info = stat()
            if lstat(socketPath, &info) == 0 {
                guard (info.st_uid == 0 || info.st_uid == allowedUID), info.st_mode & S_IFMT == S_IFSOCK else { throw HelperFailure.rejected(L("不安全的助手 socket 路径。", "Unsafe helper socket path.")) }
                guard unlink(socketPath) == 0 else { throw HelperFailure.rejected(L("无法清理旧助手 socket。", "Couldn't remove the old helper socket.")) }
            } else if errno != ENOENT { throw HelperFailure.rejected(L("无法检查助手 socket。", "Couldn't inspect the helper socket.")) }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw HelperFailure.rejected(L("无法创建助手 socket。", "Couldn't create the helper socket.")) }
            HelperSocket.configure(fd)
            var addr = try HelperSocket.address(socketPath)
            let oldMask = umask(0o077)
            let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            umask(oldMask)
            guard result == 0 else { close(fd); throw HelperFailure.rejected(L("无法绑定助手 socket。", "Couldn't bind the helper socket.")) }
            // 只给安装用户本人连接权限：macOS 的 staff 组包含所有本地账户，
            // 用同组可写会把 socket 暴露给其他用户（他们过不了签名校验，但能占满队列）。
            guard chown(socketPath, allowedUID, allowedGID) == 0, chmod(socketPath, 0o600) == 0,
                  listen(fd, 8) == 0 else { close(fd); unlink(socketPath); throw HelperFailure.rejected(L("无法监听助手 socket。", "Couldn't listen on the helper socket.")) }
        }

        deinit { close(fd); unlink(socketPath) }

        public func acceptRequest(timeoutMilliseconds: Int32 = 100) -> (fd: Int32, data: Data)? {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&item, 1, min(1000, max(0, timeoutMilliseconds))) > 0 else { return nil }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return nil }
            HelperSocket.configure(client)
            guard authenticate(client), let data = try? HelperSocket.receive(client) else { close(client); return nil }
            return (client, data)
        }

        private func authenticate(_ client: Int32) -> Bool {
            var uid: uid_t = 0; var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == allowedUID else { return false }
            var token = audit_token_t(); var length = socklen_t(MemoryLayout<audit_token_t>.size)
            guard getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0, length == MemoryLayout<audit_token_t>.size else { return false }
            let data = withUnsafeBytes(of: &token) { Data($0) }
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code,
                  SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
            var signing: CFDictionary?
            guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess, let info = signing as? [String: Any],
                  let flags = info[kSecCodeInfoFlags as String] as? UInt32, flags & 0x10000 != 0 else { return false }
            let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            return ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables"].allSatisfy { (entitlements[$0] as? Bool) != true }
        }
    }
}
