import DisplayCore
import Foundation
import Darwin
import PrivilegedSupport
import os

func perform(_ command: HelperCommand) -> HelperResult {
    switch command.action {
    case "write":
        guard let vendorID = command.vendorID, let productID = command.productID else {
            return HelperResult(id: command.id, ok: false, message: "非法的显示器标识。")
        }
        guard let base64Blobs = command.scaleResolutions else {
            return HelperResult(id: command.id, ok: false, message: "缺少 scale-resolutions 数据。")
        }
        let blobs = base64Blobs.compactMap { Data(base64Encoded: $0) }
        guard base64Blobs.count <= 64, blobs.count == base64Blobs.count,
              OverrideSupport.validateScaleResolutions(blobs) else {
            return HelperResult(id: command.id, ok: false, message: "scale-resolutions 数据非法。")
        }

        guard (command.productName?.utf8.count ?? 0) <= 256,
              let ppmm = command.targetDefaultPPMM, ppmm.isFinite, (0.1...20).contains(ppmm) else {
            return HelperResult(id: command.id, ok: false, message: "显示器参数非法。")
        }
        let plist: [String: Any] = [
            "DisplayProductName": command.productName?.isEmpty == false ? command.productName! : "DisplayLab Display",
            "DisplayResolutionEnabled": [
                "scale-resolutions": blobs,
                "target-default-ppmm": command.targetDefaultPPMM ?? 4.27,
                "Uncompressed": [Int](),
            ],
            "DisplayIsTV": false,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let path = OverrideSupport.overridePath(vendorID: vendorID, productID: productID)
            let store = try OwnedFileStore(path: (path as NSString).deletingLastPathComponent)
            try store.write(data, name: (path as NSString).lastPathComponent)
            return HelperResult(id: command.id, ok: true, message: "已写入 \(OverrideSupport.overridePath(vendorID: vendorID, productID: productID))")
        } catch {
            return HelperResult(id: command.id, ok: false, message: error.localizedDescription)
        }

    case "remove":
        guard let vendorID = command.vendorID, let productID = command.productID else {
            return HelperResult(id: command.id, ok: false, message: "非法的显示器标识。")
        }
        let path = OverrideSupport.overridePath(vendorID: vendorID, productID: productID)
        let directory = (path as NSString).deletingLastPathComponent
        // 目录不存在就没什么可删；不要为了“删除”先创建目录。lstat 不跟随 symlink，
        // 真正的写删由 OwnedFileStore 的 openat(O_NOFOLLOW) 把关。
        var info = stat()
        guard lstat(directory, &info) == 0 else {
            return HelperResult(id: command.id, ok: true, message: "本来就没有覆盖。")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return HelperResult(id: command.id, ok: false, message: "覆盖目录不是普通目录，已取消。")
        }
        do {
            let store = try OwnedFileStore(path: directory)
            try store.remove(name: (path as NSString).lastPathComponent)
            return HelperResult(id: command.id, ok: true, message: "已移除。")
        } catch {
            return HelperResult(id: command.id, ok: false, message: error.localizedDescription)
        }

    default:
        return HelperResult(id: command.id, ok: false, message: "未知命令。")
    }
}

let label = "app.meridian.display.helper"
let logger = Logger(subsystem: label, category: "override")
do {
    let config = try HelperConfiguration.load(label: label)
    guard config.applicationExists else { exit(0) }
    let server = try HelperSocket.Server(label: label, requirement: config.requirement, allowedUID: config.uid, allowedGID: config.gid)
    var lastAppCheck: TimeInterval = 0
    while true {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAppCheck > 5 { lastAppCheck = now; if !config.applicationExists { break } }
        guard let request = server.acceptRequest(timeoutMilliseconds: 500) else { continue }
        if let command = try? JSONDecoder().decode(HelperCommand.self, from: request.data), UUID(uuidString: command.id) != nil {
            let result = perform(command)
            if let data = try? JSONEncoder().encode(result) { try? HelperSocket.send(data, to: request.fd) }
        }
        close(request.fd)
    }
} catch { logger.error("Display helper failed: \(error.localizedDescription, privacy: .public)"); exit(1) }
