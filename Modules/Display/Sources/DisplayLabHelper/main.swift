import DisplayCore
import Foundation

// DisplayLabHelper: root LaunchDaemon that polls a command file and performs
// the whitelisted display-override writes. Same architecture as
// FanControlLabDaemon: on this machine, ad-hoc signed apps cannot open XPC
// connections to system daemons (NSXPCConnection fails with 4097), so the
// control channel is a file protocol:
//
//   app (user) writes  <home>/Library/Application Support/DisplayLab/helper-command.json
//   daemon (root) polls, executes the override write/remove/list, then writes
//   helper-result.json next to it.

let commandPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/DisplayLab/helper-command.json").path
let commandURL = URL(fileURLWithPath: commandPath)
let resultURL = commandURL.deletingLastPathComponent().appendingPathComponent("helper-result.json")

NSLog("DisplayLabHelper: starting (pid \(getpid())) commandFile=\(commandPath)")
var lastFileMtime = Date.distantPast

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
        guard blobs.count == base64Blobs.count,
              OverrideSupport.validateScaleResolutions(blobs) else {
            return HelperResult(id: command.id, ok: false, message: "scale-resolutions 数据非法。")
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
            try writeAtomically(data, path: OverrideSupport.overridePath(vendorID: vendorID, productID: productID))
            return HelperResult(id: command.id, ok: true, message: "已写入 \(OverrideSupport.overridePath(vendorID: vendorID, productID: productID))")
        } catch {
            return HelperResult(id: command.id, ok: false, message: error.localizedDescription)
        }

    case "remove":
        guard let vendorID = command.vendorID, let productID = command.productID else {
            return HelperResult(id: command.id, ok: false, message: "非法的显示器标识。")
        }
        let path = OverrideSupport.overridePath(vendorID: vendorID, productID: productID)
        guard FileManager.default.fileExists(atPath: path) else {
            return HelperResult(id: command.id, ok: true, message: "本来就没有覆盖。")
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return HelperResult(id: command.id, ok: true, message: "已移除。")
        } catch {
            return HelperResult(id: command.id, ok: false, message: error.localizedDescription)
        }

    case "list":
        let fileManager = FileManager.default
        guard let vendorDirs = try? fileManager.contentsOfDirectory(atPath: OverrideSupport.overridesRoot) else {
            return HelperResult(id: command.id, ok: true, message: "", overrides: [])
        }
        var result: [String] = []
        for vendorDir in vendorDirs where vendorDir.hasPrefix("DisplayVendorID-") {
            let vendorID = String(vendorDir.dropFirst("DisplayVendorID-".count))
            let vendorPath = "\(OverrideSupport.overridesRoot)/\(vendorDir)"
            guard let productFiles = try? fileManager.contentsOfDirectory(atPath: vendorPath) else {
                continue
            }
            for productFile in productFiles where productFile.hasPrefix("DisplayProductID-") {
                result.append("\(vendorID):\(String(productFile.dropFirst("DisplayProductID-".count)))")
            }
        }
        return HelperResult(id: command.id, ok: true, message: "", overrides: result)

    default:
        return HelperResult(id: command.id, ok: false, message: "未知命令 \(command.action)。")
    }
}

func writeAtomically(_ data: Data, path: String) throws {
    let fileManager = FileManager.default
    let directory = (path as NSString).deletingLastPathComponent
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [
        .posixPermissions: 0o755,
    ])
    let temporaryPath = path + ".tmp-\(getpid())"
    fileManager.createFile(atPath: temporaryPath, contents: data, attributes: [
        .posixPermissions: 0o644,
    ])
    if fileManager.fileExists(atPath: path) {
        try fileManager.removeItem(atPath: path)
    }
    try fileManager.moveItem(atPath: temporaryPath, toPath: path)
}

func tick() {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: commandURL.path),
          let mtime = attributes[.modificationDate] as? Date,
          mtime > lastFileMtime else {
        return
    }
    guard let data = try? Data(contentsOf: commandURL),
          let command = try? JSONDecoder().decode(HelperCommand.self, from: data) else {
        return
    }
    lastFileMtime = mtime
    let result = perform(command)
    if let encoded = try? JSONEncoder().encode(result) {
        try? writeAtomically(encoded, path: resultURL.path)
    }
    NSLog("DisplayLabHelper: action=\(command.action) ok=\(result.ok) message=\(result.message)")
}

// Main loop: launchd keeps the daemon alive (KeepAlive); poll every second.
while true {
    tick()
    Thread.sleep(forTimeInterval: 1.0)
}
