import Foundation
import Darwin
import PrivilegedSupport

func expectFailure(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection") } catch {}
}
@main struct Smoke {
    static func main() throws {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let body = Data("hello".utf8)
        try HelperSocket.send(body, to: fds[0])
        let received = try HelperSocket.receive(fds[1])
        precondition(received == body)
        let oversized: [UInt8] = [0, 1, 0, 1]
        _ = oversized.withUnsafeBytes { Darwin.write(fds[0], $0.baseAddress, $0.count) }
        expectFailure { _ = try HelperSocket.receive(fds[1]) }
        let partial: [UInt8] = [0, 0, 0, 5, 1]
        _ = partial.withUnsafeBytes { Darwin.write(fds[0], $0.baseAddress, $0.count) }
        shutdown(fds[0], SHUT_WR)
        expectFailure { _ = try HelperSocket.receive(fds[1]) }
        expectFailure { try HelperSocket.send(Data(repeating: 0, count: 65_537), to: fds[0]) }

        // 帧长上限正好 65536 的边界：头合法但还没发正文时必须超时失败，而不是无限等待。
        var more: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &more) == 0)
        defer { close(more[0]); close(more[1]) }
        let maximumHeader: [UInt8] = [0, 1, 0, 0]
        _ = maximumHeader.withUnsafeBytes { Darwin.write(more[0], $0.baseAddress, $0.count) }
        let started = ProcessInfo.processInfo.systemUptime
        expectFailure { _ = try HelperSocket.receive(more[1], timeout: 0.05) }
        precondition(ProcessInfo.processInfo.systemUptime - started < 2, "receive must honour its deadline")

        // 空消息既不该发也不该被接受。
        expectFailure { try HelperSocket.send(Data(), to: more[0]) }
        var zero: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &zero) == 0)
        defer { close(zero[0]); close(zero[1]) }
        let zeroHeader: [UInt8] = [0, 0, 0, 0]
        _ = zeroHeader.withUnsafeBytes { Darwin.write(zero[0], $0.baseAddress, $0.count) }
        expectFailure { _ = try HelperSocket.receive(zero[1]) }
        shutdown(zero[0], SHUT_WR)
        close(zero[0])
        close(zero[1])

        // 非 root 进程无法起服务端；socket 权限由服务端用 chown/chmod 收窄。
        expectFailure { _ = try HelperSocket.Server(label: "app.meridian.test", requirement: "identifier \"x\"",
                                                    allowedUID: 1, allowedGID: 1) }
        expectFailure { _ = try HelperSocket.Server(label: "bad label!", requirement: "identifier \"x\"",
                                                    allowedUID: getuid(), allowedGID: getgid()) }
        expectFailure { _ = try HelperSocket.Server(label: "app.meridian.test", requirement: "not a requirement",
                                                    allowedUID: 0, allowedGID: getgid()) }

        // 路径拼接只接受合法 label；注入斜杠的方式在服务端会被拒。
        precondition(HelperSocket.path("app.meridian.display.helper") == "/var/run/app.meridian.display.helper.sock")

        // OwnedFileStore：新文件可写可删；不属于 Meridian 的同名文件必须拒绝覆盖和删除。
        // 临时目录的真实路径（/var 是指向 /private/var 的符号链接，store 会拒绝）。
        func realPath(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let root = URL(fileURLWithPath: realPath(NSTemporaryDirectory()))
            .appendingPathComponent("owned-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OwnedFileStore(path: root.path)
        try store.write(Data("first".utf8), name: "DisplayProductID-1")
        try store.write(Data("second".utf8), name: "DisplayProductID-1")
        try store.remove(name: "DisplayProductID-1")
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("DisplayProductID-1").path))

        let foreign = Data("other software".utf8)
        try foreign.write(to: root.appendingPathComponent("DisplayProductID-2"))
        expectFailure { try store.write(Data("mine".utf8), name: "DisplayProductID-2") }
        expectFailure { try store.remove(name: "DisplayProductID-2") }
        let survivor = try Data(contentsOf: root.appendingPathComponent("DisplayProductID-2"))
        precondition(survivor == foreign, "third-party contents must survive")

        // 有了 Meridian 回执的文件可以继续更新；回执与内容不符时按第三方保护处理。
        try store.write(Data("x".utf8), name: "DisplayProductID-3")
        try Data("tampered".utf8).write(to: root.appendingPathComponent("DisplayProductID-3"))
        expectFailure { try store.write(Data("y".utf8), name: "DisplayProductID-3") }
        print("PrivilegedSupportSmoke ok")
    }
}
