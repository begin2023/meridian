import Foundation

/// 写入链路实验：desired.json → root daemon → SMC 的完整链路。
/// 写 F0Tg=最大转速采样实际转速；若被固件拉回再试模式键 F0Md=1；结束恢复自动。
enum FanWriteExperiment {
    static var controlFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FanControlLab/desired.json")
    }

    static func run(client: SMCClient?) {
        guard let client else {
            NSLog("EXP-FAIL: SMC client unavailable")
            exit(1)
        }
        guard DaemonInstaller().status == .enabled else {
            NSLog("EXP-FAIL: daemon 未安装")
            exit(1)
        }
        NSLog("EXP: daemon installed, starting experiment")

        func writeControl(targets: [String: Double?] = [:], modes: [String: Int]? = nil, validSeconds: Double) {
            let file = ControlFile(expiresAt: Date().timeIntervalSince1970 + validSeconds,
                                   targets: targets, modes: modes)
            let directory = controlFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(file) {
                try? data.write(to: controlFileURL, options: .atomic)
            }
        }

        func sample(_ label: String, seconds: Int) {
            for _ in 0..<(seconds * 2) {
                let actual = client.readRPM("F0Ac") ?? 0
                let target = client.readRPM("F0Tg") ?? 0
                let mode = client.readBytes("F0Md", size: 4).map { $0.map { String($0) }.joined(separator: ",") } ?? "-"
                NSLog("EXP sample[\(label)] F0Ac=\(actual) F0Tg=\(target) F0Md=[\(mode)]")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        let maxRPM = client.readRPM("F0Mx") ?? 4900

        NSLog("EXP: baseline")
        sample("base", seconds: 2)

        // 第一步：仅写 F0Tg
        writeControl(targets: ["0": maxRPM], validSeconds: 12)
        NSLog("EXP: desired F0Tg=\(maxRPM) written")
        sample("tg-only", seconds: 6)

        // 第二步：若实际转速没跟上，先写模式键 F0Md=1 再写目标
        let afterOnly = client.readRPM("F0Ac") ?? 0
        if afterOnly >= maxRPM * 0.8 {
            NSLog("EXP: F0Tg-only 已生效，无需模式键")
        } else {
            NSLog("EXP: F0Tg-only 未生效（F0Ac=\(afterOnly)），尝试 F0Md=1")
            writeControl(targets: ["0": maxRPM], modes: ["0": 1], validSeconds: 10)
            sample("mode+tg", seconds: 6)
        }

        // 恢复：控制文件立即过期 + 模式键归零，风扇回到系统自控
        writeControl(modes: ["0": 0], validSeconds: 0)
        NSLog("EXP: control expired, fan returns to system")
        sample("restored", seconds: 2)
        NSLog("EXP: done")
        exit(0)
    }
}
